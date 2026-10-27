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

      # A stock that does not belong to this market would be read from the
      # wrong .day directory -- and the file is not there, so its factors
      # would come out as 1.0 and be stored under the wrong market. Such a
      # stock is refused rather than stored.
      mismatched = stocks.reject { |stock| stock.start_with?(@area) }
      stocks -= mismatched
      failures = mismatched.to_h { |stock| [stock, "does not belong to the #{@area} market"] }
      report = report.with(failures: failures)
      return report if stocks.empty?

      deadline = budget ? Time.now + budget : nil
      begin
        result = @fetcher.call(stocks, deadline: deadline)
      rescue CorporateActionFetcher::NoServerAvailable => error
        # Not one server would answer. Nothing was fetched, so nothing is
        # written and every stock is reported as unanswered.
        return report.with(failures: failures.merge(stocks.to_h { |stock| [stock, error.message] }))
      end

      rebuilt = CorporateActionRebuilder.new(area: @area, events_by_stock: result.events)
                                      .call(result.events.keys)

      report.with(
        events: rebuilt.events,
        stored: rebuilt.stored,
        failures: failures.merge(result.failures),
        anomalies: rebuilt.anomalies
      )
    end

    # The stocks whose returns the app measures.
    def self.measured_stocks(area)
      CorporateActionRebuilder.measured_stocks(area)
    end
  end
end
