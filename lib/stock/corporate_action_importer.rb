module Stock
  # Fetches a market's ex-rights records from the TongdaXin quote servers and
  # stores them, with the adjustment factors they imply.
  #
  # A stock the servers will not answer for is reported as a failure, not as
  # a stock without events: only the second may be written, because a
  # missing record means the price is never adjusted.
  class CorporateActionImporter
    Report = Data.define(:stocks, :events, :stored, :failures, :anomalies)

    def initialize(area:, fetcher: CorporateActionFetcher.new)
      @area = area
      @fetcher = fetcher
    end

    def call(stocks, budget: nil)
      stocks = Array(stocks).uniq.sort
      report = Report.new(stocks: stocks.size, events: 0, stored: 0, failures: {}, anomalies: [])
      return report if stocks.empty?

      deadline = budget ? Time.now + budget : nil
      begin
        result = @fetcher.call(stocks, deadline: deadline)
      rescue CorporateActionFetcher::NoServerAvailable => error
        # Not one server would answer. Nothing was fetched, so nothing is
        # written and every stock is reported as unanswered.
        return report.with(failures: stocks.to_h { |stock| [stock, error.message] })
      end

      rebuilt = CorporateActionRebuilder.new(area: @area, events_by_stock: result.events)
                                      .call(result.events.keys)

      report.with(
        events: rebuilt.events,
        stored: rebuilt.stored,
        failures: result.failures,
        anomalies: rebuilt.anomalies
      )
    end

    # The stocks whose returns the app measures.
    def self.measured_stocks(area)
      CorporateActionRebuilder.measured_stocks(area)
    end
  end
end
