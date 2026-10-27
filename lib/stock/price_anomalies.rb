module Stock
  # The adjusted daily moves no A-share can make.
  #
  # A stock whose adjusted series moves more than its board allows on one day
  # has a factor that is wrong: the vendor missed an ex-rights record, or
  # dated one differently, so the price dropped without a dividend or a
  # split behind it. The event study finds the same days and drops the
  # returns whose holding window crosses them
  # (research/event_study/analyze.py, impossible_days).
  class PriceAnomalies
    # The flagged days of one area, grouped by stock.
    def self.for(area)
      rows = StockPriceAnomaly.where(area: area).order(:date).pluck(:stock, :date)
      new(rows.group_by(&:first).transform_values { |pairs| pairs.map(&:last) })
    end

    def initialize(by_stock)
      @by_stock = by_stock
    end

    # Whether the window from the entry close to the exit close contains one
    # of the stock's flagged days. Both ends count: a suspect entry price or
    # a suspect exit price makes the return suspect.
    def crosses?(stock, entry_date, exit_date)
      dates = @by_stock[stock]
      return false if dates.nil? || dates.empty?

      index = dates.bsearch_index { |date| date >= entry_date }
      index = dates.size if index.nil?
      return false if index >= dates.size

      dates[index] <= exit_date
    end

    def empty?
      @by_stock.empty?
    end
  end
end
