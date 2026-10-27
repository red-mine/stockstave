require "socket"
require "timeout"
require "zlib"

module Stock
  # A minimal TongdaXin quote-server client, speaking just enough of the
  # protocol to answer one question: which corporate actions a stock had.
  #
  # The wire format is the one pytdx speaks, because the event study already
  # fetches its ex-rights records that way (research/event_study/fetch_xdxr.py)
  # and the app's prices only match the study's when the records come from the
  # same place. Reproducing the format in Ruby keeps the nightly refresh from
  # needing a Python runtime.
  #
  #   * a request is a raw byte string; the reply is a 16 byte header followed
  #     by a body, and the header's last two 16 bit fields give how many body
  #     bytes to read and how many they inflate to;
  #   * a connection opens with three handshake packets;
  #   * the ex-rights query is a fixed 13 byte prefix followed by the market
  #     byte and the six character code; the reply is a 9 byte preamble, a
  #     record count, then that many 29 byte records.
  #
  # The server matches replies to requests by order, so exactly one query is
  # outstanding at a time. A reply that does not arrive leaves the stream out
  # of step: the caller reconnects rather than carrying on, because a late
  # reply would otherwise be read as the answer to the next stock.
  class TdxQuote
    HEADER_SIZE = 16
    PREAMBLE_SIZE = 11
    RECORD_SIZE = 29
    XDXR_PREFIX = [
      0x0c, 0x1f, 0x18, 0x76, 0x00, 0x01, 0x0b, 0x00,
      0x0b, 0x00, 0x0f, 0x00, 0x01, 0x00
    ].pack("C*")
    HANDSHAKE = [
      [0x0c, 0x02, 0x18, 0x93, 0x00, 0x01, 0x03, 0x00, 0x03, 0x00, 0x0d, 0x00, 0x01].pack("C*"),
      [0x0c, 0x02, 0x18, 0x94, 0x00, 0x01, 0x03, 0x00, 0x03, 0x00, 0x0d, 0x00, 0x02].pack("C*"),
      [
        0x0c, 0x03, 0x18, 0x99, 0x00, 0x01, 0x20, 0x00, 0x20, 0x00, 0xdb, 0x0f, 0xd5,
        0xd0, 0xc9, 0xcc, 0xd6, 0xa4, 0xa8, 0xaf, 0x00, 0x00, 0x00, 0x8f, 0xc2, 0x25,
        0x40, 0x13, 0x00, 0x00, 0xd5, 0x00, 0xc9, 0xcc, 0xbd, 0xf0, 0xd7, 0xea, 0x00,
        0x00, 0x00, 0x02
      ].pack("C*")
    ].freeze

    # The market byte the quote servers expect.
    MARKETS = { SZSTK => 0, SHSTK => 1, BJSTK => 2 }.freeze

    # The two record categories that move a price: an ex-dividend or
    # ex-rights event, and a share split. The others (new issues, non-tradable
    # share changes, warrants) leave the traded price where it was.
    CATEGORY_EX_RIGHTS = 1
    CATEGORY_RESIZE = 11

    def initialize(host, port: 7709, connect_timeout: 5, read_timeout: 15)
      @host = host
      @port = port
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @socket = nil
    end

    def connect
      @socket = TCPSocket.new(@host, @port, connect_timeout: @connect_timeout)
      HANDSHAKE.each { |packet| exchange(packet) }
      self
    end

    def disconnect
      @socket&.close
      @socket = nil
    end

    # The stock's ex-rights records, oldest first. Each one carries the
    # ex-date, the category, and the terms per ten shares.
    def ex_rights(area, stock)
      code = stock.delete_prefix(area)
      market = MARKETS.fetch(area)
      body = exchange(XDXR_PREFIX + [market].pack("C") + code.b.ljust(6, "\0"))
      parse(body, market, code)
    end

    private
      def exchange(packet)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @read_timeout
        @socket.write(packet)
        header = read_exactly(HEADER_SIZE, deadline)
        _flag, _sequence, _length, zipsize, unzipsize = header.unpack("V3v2")
        body = read_exactly(zipsize, deadline)
        body = Zlib::Inflate.inflate(body) if zipsize != unzipsize
        body
      end

      # Ruby has no per-read timeout for sockets, so the wait is spelled out:
      # wait for the socket to become readable, then take whatever is there.
      def read_exactly(count, deadline)
        buffer = +"".b
        while buffer.bytesize < count
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Timeout::Error, "the quote server did not answer in time" if remaining <= 0
          unless @socket.wait_readable(remaining)
            raise Timeout::Error, "the quote server did not answer in time"
          end

          chunk = @socket.read_nonblock(count - buffer.bytesize, exception: false)
          case chunk
          when :wait_readable then next
          when nil then raise IOError, "the quote server closed the connection"
          else buffer << chunk
          end
        end
        buffer
      end

      def parse(body, market, code)
        return [] if body.nil? || body.bytesize < PREAMBLE_SIZE

        # The reply opens with two fixed bytes, the market, the code it was
        # asked about, and the record count. A reply that echoes a different
        # code belongs to an earlier question -- the stream is out of step --
        # so it is refused rather than read as this stock's answer.
        echoed_market = body.byteslice(2, 1).unpack1("C")
        echoed_code = body.byteslice(3, 6).delete("\0")
        unless echoed_market == market && echoed_code == code
          raise IOError, "the quote server answered for #{echoed_code.presence || echoed_market} instead of #{code}"
        end

        count = body.byteslice(PREAMBLE_SIZE - 2, 2).unpack1("v")
        events = []
        position = PREAMBLE_SIZE
        count.times do
          break if body.bytesize < position + RECORD_SIZE

          position += 7   # the market byte and the six character code
          position += 1   # a byte the reference parser skips
          date = body.byteslice(position, 4).unpack1("V")
          position += 4
          category = body.byteslice(position, 1).unpack1("C")
          position += 1
          payload = body.byteslice(position, 16)
          position += 16

          event = build_event(date, category, payload)
          events << event if event
        end
        events
      end

      def build_event(date, category, payload)
        year = date / 10_000
        month = (date % 10_000) / 100
        day = date % 100
        return nil unless year.positive? && month.between?(1, 12) && day.between?(1, 31)

        event = {
          date: Date.new(year, month, day),
          category: category,
          cash: 0.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 0.0
        }
        case category
        when CATEGORY_EX_RIGHTS
          # The record holds fenhong, peigujia, songzhuangu and peigu: the
          # cash dividend, the rights subscription price, the bonus shares and
          # the rights issue ratio, all per ten shares.
          cash, rights_price, bonus, rights = payload.unpack("e4")
          event.merge!(cash: cash, bonus: bonus, rights: rights, rights_price: rights_price)
        when CATEGORY_RESIZE
          # The third field of a split record is the new share count ratio.
          event[:resize] = payload.unpack("IIfI")[2]
        end
        event
      end
  end
end
