module Stock
  # A TongdaXin .day file's full history.
  #
  # The engine reads a window from the end of the file, but the price
  # adjustment needs every close: an ex-rights event's reference price is the
  # close before its date, which can be years back.
  class DayFile
    RECORD_SIZE = 32
    DATE_OFFSET = 0
    CLOSE_OFFSET = 16

    def initialize(area, stock)
      @area = area
      @stock = stock
    end

    # The stock's first trading day, or nil when the file is missing.
    #
    # The adjustment needs to know when a stock listed, because a listing is
    # exempt from the daily price limit for its first five sessions.
    def first_date
      path = path_for(@area, @stock)
      return nil unless File.file?(path)
      return nil if File.size(path) < RECORD_SIZE

      File.open(path, "rb") do |file|
        date_of(file.read(4).unpack1("V"))
      end
    end

    # [[Date, Float], ...] oldest first. Empty when the file is missing.
    def closes
      path = path_for(@area, @stock)
      return [] unless File.file?(path)

      binary = File.binread(path)
      count = binary.bytesize / RECORD_SIZE
      Array.new(count) do |index|
        offset = index * RECORD_SIZE
        date = date_of(binary.byteslice(offset + DATE_OFFSET, 4).unpack1("V"))
        close = binary.byteslice(offset + CLOSE_OFFSET, 4).unpack1("V").fdiv(PRICE_SCALE)
        [date, close]
      end.compact
    end

    private
      def date_of(value)
        year = value / 10_000
        month = (value % 10_000) / 100
        day = value % 100
        return nil unless year.positive? && month.between?(1, 12) && day.between?(1, 31)

        Date.new(year, month, day)
      rescue Date::Error
        nil
      end

      def path_for(area, stock)
        File.join(::Stock.data_root, area, "lday", "#{stock}.day")
      end
  end
end
