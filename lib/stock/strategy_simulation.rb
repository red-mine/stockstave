module Stock
  class StrategySimulation
    STARTING_CASH = 100_000.0
    MAX_HOLD_DAYS = 20
    MAX_POSITIONS = 10
    MINIMUM_DATES = SignalPerformance::MINIMUM_DATES
    # ~0.03% broker commission on buys; ~0.03% commission + 0.05% PRC stamp
    # duty (levied on sells only) on sells.
    BUY_COST_RATE = 0.0003
    SELL_COST_RATE = 0.0008

    # Grid sizing scales each entry with how deep price sits in the
    # pessimistic five-line zone at the fill, read from the snapshot's stave
    # zone code: -3 = below the -2SD line (deepest), -2 = between -1SD and
    # -2SD, anything else keeps the base weight. This is the strategy's own
    # grid idea — the four bands as laddered entry zones, weighted by depth
    # of pessimism instead of a flat equal-weight split.
    GRID_WEIGHTS = { -3 => 2.0, -2 => 1.5 }.freeze
    BASE_WEIGHT = 1.0
    SIZING_MODES = %i[equal grid].freeze

    Result = Data.define(:ready, :dates, :starting_cash, :final_equity, :total_return, :max_drawdown, :trades, :equity_curve, :anomalous_trades)
    Trade = Data.define(:stock, :entry_date, :exit_date, :entry_price, :exit_price, :return_pct, :reason, :weight, :zone)
    EquityPoint = Data.define(:date, :equity)
    # entry_cash is the gross cash committed before buy_cost_rate is deducted;
    # allocated_capital is the net exposure that actually tracks price moves.
    Position = Struct.new(:stock, :entry_index, :entry_date, :entry_price, :entry_cash, :allocated_capital, :last_price, :weight, :zone)

    def initialize(area, starting_cash: STARTING_CASH, max_hold_days: MAX_HOLD_DAYS,
                   max_positions: MAX_POSITIONS, buy_cost_rate: BUY_COST_RATE, sell_cost_rate: SELL_COST_RATE,
                   sizing: :equal, adjusted: true)
      @area = area
      @starting_cash = starting_cash.to_f
      @max_hold_days = max_hold_days
      @max_positions = max_positions
      @buy_cost_rate = buy_cost_rate
      @sell_cost_rate = sell_cost_rate
      # Measuring on raw closes is a diagnostic, not a second opinion: it
      # shows what the adjustment changed, by running everything else the
      # same way. The simulation the app publishes always measures on adjusted
      # prices.
      @adjusted = adjusted
      raise ArgumentError, "Unknown sizing mode: #{sizing.inspect}" unless SIZING_MODES.include?(sizing)

      @sizing = sizing
    end

    def call
      dates = StockSignalSnapshot.where(area: @area).distinct.order(:signal_date).pluck(:signal_date)
      return not_ready(dates.size) if dates.size < MINIMUM_DATES

      snapshots_by_date = StockSignalSnapshot.where(area: @area, signal_date: dates)
        .group_by(&:signal_date)
        .transform_values { |rows| rows.index_by(&:stock) }

      # The account is measured on the prices a shareholder would have seen:
      # dividend- and split-adjusted closes, the same prices the event study
      # measures on. The signals that fill the account still come from the
      # raw close.
      @factors = if @adjusted
        PriceAdjustment.factors_for(@area, snapshots_by_date.values.flat_map(&:keys).uniq)
      else
        PriceAdjustment::Factors.new([])
      end
      @anomalies = PriceAnomalies.for(@area)
      @anomalous_trades = 0

      cash = @starting_cash
      positions = {}
      trades = []
      equity_curve = []
      # Stocks that showed a buy signal at the previous close. They are filled
      # at the *next* close, because the signal is derived from the close that
      # produced it — trading that same close would spend information the
      # decision did not have yet.
      queued = []

      dates.each_with_index do |date, index|
        today = snapshots_by_date[date] || {}

        # 1. Exits, priced at today's close. A position filled today is not in
        #    `positions` yet, so it cannot be evaluated for exit today.
        positions.keys.each do |stock|
          position = positions[stock]
          snapshot = today[stock]
          position.last_price = @factors.price(stock, date, snapshot.price) if snapshot

          reason = exit_reason(snapshot, position, index)
          next unless reason

          cash += close_position!(trades, position, date, position.last_price, reason)
          positions.delete(stock)
        end

        # 2. Yesterday's signals are filled at today's close.
        cash = fill_entries(cash, queued, today, positions, index, date)

        # 3. Today's signals queue up for tomorrow's fill. The last recorded
        #    date is scanned but never traded, because it has no tomorrow.
        queued = queue_entries(today, positions)

        equity = cash + positions.values.sum { |position| position.allocated_capital * (position.last_price / position.entry_price) }
        equity_curve << EquityPoint.new(date: date, equity: rounded(equity))
      end

      positions.each_value do |position|
        cash += close_position!(trades, position, dates.last, position.last_price, "end_of_data")
      end

      Result.new(
        ready: true,
        dates: dates.size,
        starting_cash: @starting_cash,
        final_equity: rounded(cash),
        total_return: rounded((cash / @starting_cash - 1) * 100),
        max_drawdown: rounded(max_drawdown(equity_curve)),
        trades: trades,
        equity_curve: equity_curve,
        anomalous_trades: @anomalous_trades
      )
    end

    private

    def not_ready(dates_count)
      Result.new(
        ready: false, dates: dates_count, starting_cash: @starting_cash, final_equity: @starting_cash,
        total_return: 0.0, max_drawdown: 0.0, trades: [], equity_curve: [], anomalous_trades: 0
      )
    end

    def fill_entries(cash, queued, today, positions, index, date)
      slots = @max_positions - positions.size
      return cash if cash <= 0 || slots <= 0 || queued.empty?

      fillable = queued
        .reject { |stock| positions.key?(stock) }
        .select { |stock| tradable?(today[stock]) }
        .first(slots)
      return cash if fillable.empty?

      weights = fillable.map { |stock| entry_weight(today[stock]) }
      total_weight = weights.sum

      spent = 0.0
      fillable.each_with_index do |stock, offset|
        per_position = cash * weights[offset] / total_weight
        spent += per_position
        price = @factors.price(stock, date, today[stock].price)
        positions[stock] = Position.new(stock, index, date, price, per_position, per_position * (1 - @buy_cost_rate), price, weights[offset], today[stock].lohas_stave)
      end

      cash - spent
    end

    # Equal sizing is the degenerate case: every weight is 1.0, so the split
    # stays cash / n.
    def entry_weight(snapshot)
      return BASE_WEIGHT unless @sizing == :grid

      GRID_WEIGHTS.fetch(snapshot&.lohas_stave, BASE_WEIGHT)
    end

    # Selection is by stock code when there are more signals than slots. That is
    # arbitrary, but it is blind to what happens next, so it cannot smuggle
    # future performance into the result.
    def queue_entries(today, positions)
      today
        .reject { |stock, _| positions.key?(stock) }
        .select { |_stock, snapshot| tradable?(snapshot) && SignalFamily.classify(snapshot.year_signal, snapshot.lohas_signal) == "buy" }
        .keys
        .sort
    end

    def tradable?(snapshot)
      snapshot && snapshot.price.to_f.positive?
    end

    def exit_reason(snapshot, position, index)
      return "sell" if snapshot && SignalFamily.classify(snapshot.year_signal, snapshot.lohas_signal) == "sell"
      return "timeout" if index - position.entry_index >= @max_hold_days

      nil
    end

    def close_position!(trades, position, exit_date, exit_price, reason)
      raw_proceeds = position.allocated_capital * (exit_price / position.entry_price)
      net_proceeds = raw_proceeds * (1 - @sell_cost_rate)

      # A trade whose holding period covers a day whose adjusted move no
      # board allows is reported rather than quietly counted: that day means
      # a factor is wrong, so the return across it is not a number anyone
      # should act on. The event study drops the same windows
      # (analyze.py, forward_returns); an account cannot un-buy a position,
      # so the simulation keeps it and says so.
      @anomalous_trades += 1 if @anomalies.crosses?(position.stock, position.entry_date, exit_date)

      trades << Trade.new(
        stock: position.stock, entry_date: position.entry_date, exit_date: exit_date,
        entry_price: position.entry_price, exit_price: exit_price,
        return_pct: rounded((net_proceeds / position.entry_cash - 1) * 100),
        reason: reason, weight: position.weight, zone: position.zone
      )
      net_proceeds
    end

    def max_drawdown(equity_curve)
      peak = -Float::INFINITY
      worst = 0.0
      equity_curve.each do |point|
        peak = point.equity if point.equity > peak
        drawdown = (point.equity - peak).fdiv(peak) * 100
        worst = drawdown if drawdown < worst
      end
      worst
    end

    def rounded(value)
      value.round(2)
    end
  end
end
