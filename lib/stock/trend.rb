module Stock
  module Trend
    # The band names live in the locale file: a label is a word for a reader,
    # not a fact about a slope, so it does not belong to the calculation.
    LABELS = {
      "strong_uptrend" => :"trend.strong_uptrend",
      "uptrend" => :"trend.uptrend",
      "weak_uptrend" => :"trend.weak_uptrend",
      "flat" => :"trend.flat",
      "downtrend" => :"trend.downtrend",
      "unknown" => :"trend.unknown"
    }.freeze

    module_function

    # Turns a regression slope into a band. This was once implemented twice --
    # once for the index page's buy candidates and once for a stock's own trend
    # health -- and the two copies could disagree about what "uptrend" means.
    # The edges below differ by a single character (> versus >=), so each one
    # is pinned by test/lib/stock/trend_test.rb.
    def classify(coef)
      return "unknown" if coef.nil?

      c = coef.to_f
      return "strong_uptrend" if c >= 0.05
      return "uptrend" if c >= 0.02
      return "weak_uptrend" if c > 0.01
      return "flat" if c >= -0.01
      "downtrend"
    end

    def label(status)
      LABELS.fetch(status.to_s, :"trend.unknown")
    end
  end
end
