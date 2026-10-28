module Stock
  module SignalFamily
    BUY = %w[SAF1 BUY4 BUY5 CHP0].freeze
    SELL = %w[SEL3 SEL6 SEL7].freeze

    module_function

    def classify(year_signal, lohas_signal)
      signals = [year_signal, lohas_signal]
      return "sell" if signals.any? { |signal| signal.in?(SELL) }
      return "buy" if signals.all? { |signal| signal.in?(BUY) }

      "watch"
    end

    # The names and the explanations live in the locale file, so the family
    # can be read in either language without a second copy of the wording.
    def label(family)
      { "buy" => :"signal_family.buy", "sell" => :"signal_family.sell", "watch" => :"signal_family.watch" }.fetch(family)
    end

    def explanation(family)
      {
        "buy" => :"signal_family.explanation.buy",
        "sell" => :"signal_family.explanation.sell",
        "watch" => :"signal_family.explanation.watch"
      }.fetch(family)
    end
  end
end
