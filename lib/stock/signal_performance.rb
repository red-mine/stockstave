module Stock
  class SignalPerformance
    MINIMUM_DATES = 20
    MINIMUM_SAMPLE = 5
    # A signal is judged against the stocks the strategy could have picked that
    # day, so the baseline needs enough of them to mean anything. The event
    # study makes the same demand (`j[j["base_n"] >= 20]` in analyze.py).
    MINIMUM_BASELINE_SAMPLE = 20

    Report = Data.define(:ready, :dates, :horizon, :cohorts, :baseline)
    Cohort = Data.define(
      :year_signal, :lohas_signal, :sample_size, :win_rate,
      :average_return, :average_drawdown, :trend_group,
      :baseline_return, :excess_return, :excess_dates
    )
    Baseline = Data.define(:average_return, :dates, :sample_size)

    def initialize(area, horizon: 5)
      @area = area
      @horizon = horizon
    end

    def call(signal_type: :buy, group_by_trend: false)
      scope = StockSignalSnapshot.where(area: @area)
      dates = scope.distinct.order(:signal_date).pluck(:signal_date)
      return not_ready(dates.size) if dates.size < MINIMUM_DATES

      by_date = scope.order(:signal_date).to_a
                      .group_by(&:signal_date)
                      .transform_values { |rows| rows.index_by(&:stock) }

      # The report measures what a shareholder would have earned, so the
      # prices it works from are the dividend- and split-adjusted ones -- the
      # same prices the event study measures on. The signal itself was, and
      # still is, derived from the raw close.
      factors = PriceAdjustment.factors_for(@area, by_date.values.flat_map(&:keys).uniq)
      anomalies = PriceAnomalies.for(@area)

      outcomes = forward_outcomes(by_date, dates, factors, anomalies)
      baselines = baseline_by_date(outcomes)

      Report.new(
        ready: true,
        dates: dates.size,
        horizon: @horizon,
        cohorts: build_cohorts(by_date, outcomes, baselines, signal_type, group_by_trend),
        baseline: summarise_baseline(baselines)
      )
    end

    private
      def not_ready(dates_count)
        Report.new(
          ready: false,
          dates: dates_count,
          horizon: @horizon,
          cohorts: [],
          baseline: Baseline.new(average_return: nil, dates: 0, sample_size: 0)
        )
      end

      # A signal is derived from a close, so that close is not tradable: the
      # first close after it is. StrategySimulation fills there, and the event
      # study enters there ("Entry at the close of the first trading day after
      # the signal date D"). This report used to measure from the signal day's
      # own close, which put the decision's own move inside the "forward"
      # return it was judging — the same close the decision could not yet act
      # on was the one it was credited with.
      #
      # A holding period that crosses a day whose adjusted move no board
      # allows is dropped: that day means a factor is wrong, so the return
      # across it is not a number anyone should act on. The event study drops
      # the same windows (analyze.py, forward_returns).
      def forward_outcomes(by_date, dates, factors, anomalies)
        outcomes = {}

        dates.each_with_index do |date, index|
          entry_position = index + 1
          exit_position  = entry_position + @horizon
          next if exit_position >= dates.size

          universe  = by_date[date]
          entry_map = by_date[dates[entry_position]]
          exit_map  = by_date[dates[exit_position]]

          entry_date = dates[entry_position]
          exit_date  = dates[exit_position]

          per_stock = {}
          universe.each do |stock, _snapshot|
            entry         = entry_map[stock]
            exit_snapshot = exit_map[stock]
            next unless entry && exit_snapshot
            next unless valid_prices?(entry, exit_snapshot)
            next if anomalies.crosses?(stock, entry_date, exit_date)

            path = (entry_position..exit_position).filter_map do |position|
              snapshot = by_date[dates[position]]&.dig(stock)
              snapshot && factors.price(stock, dates[position], snapshot.price)
            end
            next unless path.size == @horizon + 1

            entry_price = path.first
            per_stock[stock] = {
              return: percentage_change(entry_price, path.last),
              drawdown: path.map { |price| percentage_change(entry_price, price) }.min
            }
          end

          outcomes[date] = per_stock unless per_stock.empty?
        end

        outcomes
      end

      # The baseline is every stock the engine produced a model for that day,
      # signal or not — the pool this strategy was choosing from. A cohort that
      # merely rises with the market has not earned anything.
      def baseline_by_date(outcomes)
        outcomes.transform_values do |per_stock|
          returns = per_stock.values.map { |outcome| outcome[:return] }
          { mean: returns.sum.fdiv(returns.size), size: returns.size }
        end
      end

      def build_cohorts(by_date, outcomes, baselines, signal_type, group_by_trend)
        buckets = Hash.new { |hash, key| hash[key] = Hash.new { |inner, _date| inner[_date] = [] } }

        outcomes.each do |date, per_stock|
          universe = by_date[date]
          per_stock.each do |stock, outcome|
            snapshot = universe[stock]
            next unless signal_match?(snapshot, signal_type)

            buckets[cohort_key(snapshot, group_by_trend)][date] << outcome
          end
        end

        buckets.filter_map { |key, by_date_outcomes| build_cohort(key, by_date_outcomes, baselines) }
               .sort_by { |cohort| [-cohort.sample_size, cohort.year_signal.to_s, cohort.lohas_signal.to_s, cohort.trend_group.to_s] }
      end

      def cohort_key(snapshot, group_by_trend)
        if group_by_trend
          [
            snapshot.year_signal,
            snapshot.lohas_signal,
            trend_group(snapshot.year_trend, snapshot.long_trend)
          ]
        else
          [snapshot.year_signal, snapshot.lohas_signal, nil]
        end
      end

      def build_cohort(key, by_date_outcomes, baselines)
        year_signal, lohas_signal, trend_group = key
        observations = by_date_outcomes.values.flatten(1)
        return nil if observations.size < MINIMUM_SAMPLE

        # Date-weighted, like the event study: one day contributes one
        # observation however many stocks happened to signal on it.
        comparisons = by_date_outcomes.filter_map do |date, outcomes|
          baseline = baselines[date]
          next unless baseline && baseline[:size] >= MINIMUM_BASELINE_SAMPLE

          cohort_mean = outcomes.sum { |outcome| outcome[:return] }.fdiv(outcomes.size)
          [cohort_mean - baseline[:mean], baseline[:mean]]
        end

        Cohort.new(
          year_signal: year_signal,
          lohas_signal: lohas_signal,
          sample_size: observations.size,
          win_rate: rounded(observations.count { |outcome| outcome[:return].positive? }.fdiv(observations.size) * 100),
          average_return: rounded(observations.sum { |outcome| outcome[:return] }.fdiv(observations.size)),
          average_drawdown: rounded(observations.sum { |outcome| outcome[:drawdown] }.fdiv(observations.size)),
          trend_group: trend_group,
          baseline_return: comparisons.empty? ? nil : rounded(comparisons.sum { |pair| pair[1] }.fdiv(comparisons.size)),
          excess_return: comparisons.empty? ? nil : rounded(comparisons.sum { |pair| pair[0] }.fdiv(comparisons.size)),
          excess_dates: comparisons.size
        )
      end

      def summarise_baseline(baselines)
        usable = baselines.values.select { |baseline| baseline[:size] >= MINIMUM_BASELINE_SAMPLE }
        return Baseline.new(average_return: nil, dates: 0, sample_size: 0) if usable.empty?

        Baseline.new(
          average_return: rounded(usable.sum { |baseline| baseline[:mean] }.fdiv(usable.size)),
          dates: usable.size,
          sample_size: usable.sum { |baseline| baseline[:size] }
        )
      end

      # Membership used to be spelled out here as its own BUY_SIGNALS and
      # SELL_SIGNALS lists, and the buy/sell test restated SignalFamily.classify's
      # rule. Both could drift from the family the rest of the app filters and
      # labels by, so this asks SignalFamily directly.
      def signal_match?(snapshot, signal_type)
        return true unless signal_type == :buy || signal_type == :sell

        SignalFamily.classify(snapshot.year_signal, snapshot.lohas_signal) == signal_type.to_s
      end

      def trend_group(year_trend, long_trend)
        # A third copy of the slope thresholds used to live here. The values it
        # produced were identical to Stock::Trend's: nil slopes are dropped by
        # compact before this map, so Trend.classify's "unknown" never fires.
        trends = [year_trend, long_trend].compact.map { |c| Trend.classify(c) }
        return "mixed" if trends.uniq.size > 1
        trends.first || "unknown"
      end

      def valid_prices?(entry, exit_snapshot)
        entry.price.to_f.positive? && exit_snapshot&.price.to_f.positive?
      end

      def percentage_change(start_price, end_price)
        (end_price.to_f / start_price.to_f - 1) * 100
      end

      def rounded(value)
        value.round(2)
      end
  end
end
