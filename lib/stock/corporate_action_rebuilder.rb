module Stock
  # Recomputes a market's adjustment factors and the price anomalies they
  # imply, from the corporate actions already stored.
  #
  # A corporate action does not change once it has happened, but the closes
  # around it can be corrected, and a corrected close makes the factor wrong.
  # So the factors are re-derived from the local .day history rather than
  # assumed, and the safety net is re-run over the result: an adjusted daily
  # move no board would allow means a factor is wrong -- the vendor missed an
  # ex-rights record, or dated one differently -- and the event study finds
  # the same days (research/event_study/analyze.py, impossible_days).
  #
  # The events can come from the database or from a fetch that has just
  # happened, so the same code serves both the import and the nightly rebuild.
  class CorporateActionRebuilder
    Report = Data.define(:stocks, :events, :stored, :anomalies)

    def initialize(area:, events_by_stock: nil)
      @area = area
      @events_by_stock = events_by_stock
    end

    def call(stocks)
      stocks = Array(stocks).uniq.sort
      report = Report.new(stocks: stocks.size, events: 0, stored: 0, anomalies: [])
      return report if stocks.empty?

      first_date = earliest_listing_date(stocks)
      stored = 0
      events = 0
      anomalies = []

      stocks.each do |stock|
        records = records_for(stock)
        closes = DayFile.new(@area, stock).closes
        factors = PriceAdjustment.factors_for_events(records, closes)
        rows = build_rows(stock, records, factors)
        events += rows.size
        stored += write(rows)
        anomalies.concat(anomalies_for(stock, rows, closes, first_date))
      end

      write_anomalies(stocks, anomalies)

      report.with(events: events, stored: stored, anomalies: anomalies)
    end

    # The stocks whose returns the app measures: everything a snapshot was
    # taken of, plus everything the model tables still cover, so a stock that
    # enters the pool tomorrow is already adjusted.
    def self.measured_stocks(area)
      snapshots = StockSignalSnapshot.where(area: area).distinct.pluck(:stock)
      models = [StocksCoefsLoha, StocksCoefsYear, StocksCoefsStav].flat_map do |model|
        model.where(area: area).distinct.pluck(:stock)
      end
      (snapshots + models).uniq
    end

    private
      # The events of a stock, as the vendor's records: the terms matter for
      # the reference price, so they are read back out of the database rather
      # than inferred from the stored factor.
      def records_for(stock)
        return @events_by_stock[stock] if @events_by_stock

        StockCorporateAction.where(area: @area, stock: stock).order(:ex_date).map do |row|
          {
            date: row.ex_date, category: row.category, cash: row.cash, bonus: row.bonus,
            rights: row.rights, rights_price: row.rights_price, resize: row.resize
          }
        end
      end

      def build_rows(stock, records, factors)
        records.map do |record|
          PriceAdjustment::Event.new(
            stock: stock,
            ex_date: record[:date],
            category: record[:category],
            cash: record[:cash].to_f,
            bonus: record[:bonus].to_f,
            rights: record[:rights].to_f,
            rights_price: record[:rights_price].to_f,
            resize: record[:resize].to_f,
            factor: factors.fetch(record[:date], 1.0)
          )
        end
      end

      def write(rows)
        return 0 if rows.empty?

        now = Time.current
        StockCorporateAction.upsert_all(
          rows.map do |row|
            {
              area: @area, stock: row.stock, ex_date: row.ex_date, category: row.category,
              cash: row.cash, bonus: row.bonus, rights: row.rights, rights_price: row.rights_price,
              resize: row.resize, factor: row.factor, fetched_at: now,
              created_at: now, updated_at: now
            }
          end,
          unique_by: %i[area stock ex_date category]
        )
        rows.size
      end

      def anomalies_for(stock, rows, closes, first_date)
        factors = PriceAdjustment::Factors.new(rows)
        series = closes.map { |date, close| [date, factors.price(stock, date, close)] }

        PriceAdjustment.impossible_days(stock, series, first_date).map do |anomaly|
          anomaly.merge(stock: stock)
        end
      end

      # A stock listed after the market's first day is exempt from the daily
      # limit for its first five sessions, so the market's first day is needed
      # before any stock can be judged.
      def earliest_listing_date(stocks)
        stocks.filter_map { |stock| DayFile.new(@area, stock).first_date }.min
      end

      def write_anomalies(stocks, anomalies)
        StockPriceAnomaly.where(area: @area, stock: stocks).delete_all
        return if anomalies.empty?

        now = Time.current
        StockPriceAnomaly.insert_all(
          anomalies.map do |anomaly|
            {
              area: @area, stock: anomaly[:stock], date: anomaly[:date],
              change_pct: anomaly[:change_pct], limit_pct: anomaly[:limit_pct],
              detected_at: now, created_at: now, updated_at: now
            }
          end,
          unique_by: %i[area stock date]
        )
      end
  end
end
