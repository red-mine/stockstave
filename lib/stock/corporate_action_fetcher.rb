module Stock
  # Fetches the ex-rights records of a list of stocks from the TongdaXin
  # quote servers.
  #
  # The servers answer one stock at a time and match replies to requests by
  # order, so a lost reply leaves the stream out of step. The client refuses
  # a reply that echoes another stock's code; this fetcher treats that, and
  # any other failure, as a reason to drop the connection and ask again, on
  # the next server when it has to.
  #
  # A stock that no server would answer for is reported as a failure rather
  # than as having no events: an empty list and a failed fetch mean different
  # things, and only the first may be stored.
  class CorporateActionFetcher
    # The public TongdaXin quote servers on port 7709, the same list pytdx
    # ships and the event study walks through.
    SERVERS = [
      "218.85.139.19", "218.85.139.20", "58.23.131.163", "218.6.170.47",
      "123.125.108.14", "180.153.18.170", "180.153.18.171", "202.108.253.130",
      "202.108.253.131", "60.191.117.167", "115.238.56.198", "218.75.126.9",
      "115.238.90.165", "124.160.88.183", "60.12.136.250", "218.108.98.244",
      "218.108.47.69", "223.94.89.115", "218.57.11.101", "58.58.33.123",
      "14.17.75.71", "114.80.63.12", "114.80.63.35", "180.153.39.51",
      "119.147.212.81", "221.231.141.60", "101.227.73.20", "101.227.77.254",
      "14.215.128.18", "59.173.18.140", "60.28.23.80", "218.60.29.136",
      "122.192.35.44", "112.95.140.74", "112.95.140.92", "112.95.140.93",
      "114.80.149.19", "114.80.149.21", "114.80.149.22", "114.80.149.91",
      "114.80.149.92", "121.14.104.60", "121.14.104.66", "123.126.133.13",
      "123.126.133.14", "123.126.133.21", "211.139.150.61", "59.36.5.11",
      "119.29.19.242", "123.138.29.107", "123.138.29.108", "124.232.142.29",
      "183.57.72.11", "183.57.72.12", "183.57.72.13", "183.57.72.15",
      "183.57.72.21", "183.57.72.22", "183.57.72.23", "183.57.72.24",
      "183.60.224.177", "183.60.224.178", "113.105.92.100", "113.105.92.101",
      "113.105.92.102", "113.105.92.103", "113.105.92.104", "113.105.92.99",
      "117.34.114.13", "117.34.114.14", "117.34.114.15", "117.34.114.16",
      "117.34.114.17", "117.34.114.18", "117.34.114.20", "117.34.114.27",
      "117.34.114.30", "117.34.114.31", "182.131.3.252", "183.60.224.11",
      "58.210.106.91", "58.63.254.216", "58.63.254.219", "58.63.254.247",
      "123.125.108.90", "175.6.5.153", "182.118.47.151", "182.131.3.245",
      "202.100.166.27", "222.161.249.156", "42.123.69.62", "58.63.254.191",
      "58.63.254.217", "120.55.172.97", "139.217.20.27", "202.100.166.21",
      "202.96.138.90", "218.106.92.182", "218.106.92.183", "220.178.55.71",
      "220.178.55.86"
    ].freeze

    # Only two kinds of record move a price: an ex-dividend or ex-rights
    # event, and a share split. The others -- new issues, non-tradable share
    # changes, warrants -- leave the traded price where it was, so they are
    # not recorded. The event study keeps the same two.
    PRICE_CATEGORIES = [::Stock::TdxQuote::CATEGORY_EX_RIGHTS, ::Stock::TdxQuote::CATEGORY_RESIZE].freeze

    ATTEMPTS = 3

    Result = Data.define(:events, :failures)

    def initialize(servers: SERVERS, client_class: ::Stock::TdxQuote)
      @servers = servers
      @client_class = client_class
      @server_index = 0
      @client = nil
    end

    # Returns a Result holding the price-moving records of every stock that
    # answered, keyed by stock, and the stocks that did not answer with the
    # reason.
    def call(stocks)
      events = {}
      failures = {}

      stocks.each do |stock|
        records, error = fetch(stock)
        if records
          events[stock] = records
        else
          failures[stock] = error
        end
      end

      Result.new(events: events, failures: failures)
    ensure
      disconnect
    end

    private
      def fetch(stock)
        area = stock[0, 2]
        error = "unknown error"
        ATTEMPTS.times do
          begin
            records = client.ex_rights(area, stock)
            return [records.select { |record| PRICE_CATEGORIES.include?(record[:category]) }, nil]
          rescue StandardError => failure
            # The stream may be out of step now, so it is dropped rather than
            # reused for the next stock.
            disconnect
            error = "#{failure.class}: #{failure.message}"
          end
        end
        [nil, error]
      end

      # A connection that cannot be made moves on to the next server: the
      # list holds servers that are down as often as not.
      def client
        return @client if @client

        @servers.size.times do
          host = @servers[@server_index]
          @server_index = (@server_index + 1) % @servers.size
          begin
            @client = @client_class.new(host).connect
            return @client
          rescue StandardError
            @client = nil
          end
        end
        raise "no TongdaXin quote server answered"
      end

      def disconnect
        @client&.disconnect
        @client = nil
      rescue StandardError
        @client = nil
      end
  end
end
