require "test_helper"

class StockStrategySimulationTest < ActiveSupport::TestCase
  def snapshot(stock:, date:, price:, year_signal:, lohas_signal:, lohas_stave: nil)
    StockSignalSnapshot.create!(
      stock: stock, area: Stock::SZSTK, signal_date: date, price: price,
      year_signal: year_signal, lohas_signal: lohas_signal, lohas_stave: lohas_stave
    )
  end

  test "closes a position on a sell signal and books the realized return" do
    dates = 22.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      year_signal, lohas_signal, price = case index
      when 0 then ["BUY5", "BUY5", 10.0]
      when 3 then ["SEL7", "SEL7", 12.0]
      else ["WAT9", "WAT9", 10.0 + index * 0.1]
      end
      snapshot(stock: "sz000001", date: date, price: price, year_signal: year_signal, lohas_signal: lohas_signal)
    end

    result = Stock::StrategySimulation.new(Stock::SZSTK, buy_cost_rate: 0.0, sell_cost_rate: 0.0).call

    assert result.ready
    assert_equal 1, result.trades.size
    trade = result.trades.first
    assert_equal "sell", trade.reason
    # The signal appears at dates[0] but is derived from that close, so the
    # fill happens at the next close rather than at the signalling price.
    assert_equal dates[1], trade.entry_date
    assert_equal dates[3], trade.exit_date
    assert_in_delta 10.1, trade.entry_price, 1e-9
    assert_equal 12.0, trade.exit_price
    assert_equal 18.81, trade.return_pct
    assert_equal 118_811.88, result.final_equity
    assert_equal 18.81, result.total_return
  end

  test "force-closes a position after the max hold period without a sell signal" do
    dates = 25.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      year_signal, lohas_signal = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      snapshot(stock: "sz000001", date: date, price: 10.0 + index * 0.1, year_signal: year_signal, lohas_signal: lohas_signal)
    end

    result = Stock::StrategySimulation.new(Stock::SZSTK, max_hold_days: 20).call

    assert_equal 1, result.trades.size
    trade = result.trades.first
    assert_equal "timeout", trade.reason
    assert_equal dates[1], trade.entry_date
    assert_equal dates[21], trade.exit_date
  end

  test "splits available cash equally between same-day buy signals" do
    dates = 25.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      signals = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      snapshot(stock: "sz000001", date: date, price: 10.0, year_signal: signals[0], lohas_signal: signals[1])
      snapshot(stock: "sz000002", date: date, price: 20.0 + index * 1.0, year_signal: signals[0], lohas_signal: signals[1])
    end

    result = Stock::StrategySimulation.new(
      Stock::SZSTK, starting_cash: 100_000.0, max_hold_days: 20, buy_cost_rate: 0.0, sell_cost_rate: 0.0
    ).call

    assert_equal 100_000.0, result.equity_curve.first.equity
    assert_equal 2, result.trades.size
    flat_trade = result.trades.find { |trade| trade.stock == "sz000001" }
    doubled_trade = result.trades.find { |trade| trade.stock == "sz000002" }
    # Both are filled at the dates[1] close: 10.0 and 21.0.
    assert_in_delta 10.0, flat_trade.entry_price, 1e-9
    assert_in_delta 21.0, doubled_trade.entry_price, 1e-9
    assert_equal 0.0, flat_trade.return_pct
    assert_equal 95.24, doubled_trade.return_pct
    assert_equal 147_619.05, result.final_equity
    assert_equal 47.62, result.total_return
  end

  test "no signals ever fire leaves the starting cash untouched" do
    dates = 21.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each do |date|
      snapshot(stock: "sz000001", date: date, price: 10.0, year_signal: "WAT9", lohas_signal: "WAT9")
    end

    result = Stock::StrategySimulation.new(Stock::SZSTK).call

    assert result.ready
    assert_empty result.trades
    assert_equal 100_000.0, result.final_equity
    assert_equal 0.0, result.total_return
  end

  test "buy and sell costs reduce the realized return and final equity" do
    dates = 22.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      year_signal, lohas_signal, price = case index
      when 0 then ["BUY5", "BUY5", 10.0]
      when 3 then ["SEL7", "SEL7", 12.0]
      else ["WAT9", "WAT9", 10.0 + index * 0.1]
      end
      snapshot(stock: "sz000001", date: date, price: price, year_signal: year_signal, lohas_signal: lohas_signal)
    end

    result = Stock::StrategySimulation.new(Stock::SZSTK, buy_cost_rate: 0.01, sell_cost_rate: 0.02).call

    trade = result.trades.first
    # entry: filled at the dates[1] close of 10.1, so 100_000 * (1 - 0.01)
    #        = 99_000 net exposure buys 99_000 / 10.1 worth of stock
    # exit: 99_000 * (12.0 / 10.1) = 117_623.76 raw, * (1 - 0.02) = 115_271.29 net
    # return_pct/total_return are rounded to 2 decimals: 15.271 -> 15.27
    assert_in_delta 10.1, trade.entry_price, 1e-9
    assert_equal 115_271.29, result.final_equity
    assert_equal 15.27, trade.return_pct
    assert_equal 15.27, result.total_return
  end

  test "a signal is filled at the next close and cannot be exited on the fill day" do
    dates = 22.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      year_signal, lohas_signal = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      snapshot(stock: "sz000001", date: date, price: 10.0, year_signal: year_signal, lohas_signal: lohas_signal)
    end

    # The signal is recorded at dates[0] and filled at dates[1]. max_hold_days: 0
    # would close the position the instant it could be evaluated, so the exit
    # lands on dates[2]: the earliest a filled position can be assessed is the
    # day after the fill.
    result = Stock::StrategySimulation.new(Stock::SZSTK, max_hold_days: 0).call

    trade = result.trades.first
    assert_equal dates[1], trade.entry_date
    assert_equal dates[2], trade.exit_date
    refute_equal trade.entry_date, trade.exit_date
  end

  test "never holds more than max_positions at once" do
    dates = 25.times.map { |index| Date.new(2026, 1, 1) + index }
    stocks = 12.times.map { |index| format("sz%06d", index + 1) }
    dates.each_with_index do |date, index|
      signals = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      stocks.each do |stock|
        snapshot(stock: stock, date: date, price: 10.0, year_signal: signals[0], lohas_signal: signals[1])
      end
    end

    result = Stock::StrategySimulation.new(
      Stock::SZSTK, max_positions: 10, max_hold_days: 20, buy_cost_rate: 0.0, sell_cost_rate: 0.0
    ).call

    # 12 stocks signal a buy on the same close, but only 10 slots exist.
    assert_equal 10, result.trades.size
    assert_equal stocks.first(10), result.trades.map(&:stock).sort
    assert_equal 100_000.0, result.final_equity
  end

  test "grid sizing weights deeper pessimistic entries more heavily than shallow ones" do
    dates = 25.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      signals = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      # Deep zone -3 (below the -2SD line) and mid zone -2 (-1SD..-2SD).
      snapshot(stock: "sz000001", date: date, price: 10.0 + index * 0.1, year_signal: signals[0], lohas_signal: signals[1], lohas_stave: -3)
      snapshot(stock: "sz000002", date: date, price: 20.0 + index * 0.2, year_signal: signals[0], lohas_signal: signals[1], lohas_stave: -2)
    end

    result = Stock::StrategySimulation.new(
      Stock::SZSTK, sizing: :grid, max_hold_days: 20, buy_cost_rate: 0.0, sell_cost_rate: 0.0
    ).call

    deep, shallow = result.trades.sort_by(&:stock)
    assert_equal 2.0, deep.weight
    assert_equal -3, deep.zone
    assert_equal 1.5, shallow.weight
    assert_equal -2, shallow.zone

    # Cash splits 2.0 : 1.5 between the two fills at dates[1] (10.1 and 20.2),
    # and both positions are force-closed at dates[21] (12.1 and 24.2).
    deep_cash = 100_000.0 * 2.0 / 3.5
    shallow_cash = 100_000.0 * 1.5 / 3.5
    expected = deep_cash * (12.1 / 10.1) + shallow_cash * (24.2 / 20.2)
    assert_in_delta expected, result.final_equity, 0.01
    assert_operator result.final_equity, :>, 100_000.0
  end

  test "equal sizing on the same signals splits cash evenly" do
    dates = 25.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      signals = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      snapshot(stock: "sz000001", date: date, price: 10.0 + index * 0.1, year_signal: signals[0], lohas_signal: signals[1], lohas_stave: -3)
      snapshot(stock: "sz000002", date: date, price: 20.0 + index * 0.2, year_signal: signals[0], lohas_signal: signals[1], lohas_stave: -2)
    end

    result = Stock::StrategySimulation.new(
      Stock::SZSTK, max_hold_days: 20, buy_cost_rate: 0.0, sell_cost_rate: 0.0
    ).call

    expected = 50_000.0 * (12.1 / 10.1) + 50_000.0 * (24.2 / 20.2)
    assert_in_delta expected, result.final_equity, 0.01
    assert result.trades.all? { |trade| trade.weight == 1.0 }
  end

  test "grid sizing falls back to the base weight when the stave zone is missing" do
    dates = 25.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      signals = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      snapshot(stock: "sz000001", date: date, price: 10.0, year_signal: signals[0], lohas_signal: signals[1])
      snapshot(stock: "sz000002", date: date, price: 10.0, year_signal: signals[0], lohas_signal: signals[1])
    end

    result = Stock::StrategySimulation.new(
      Stock::SZSTK, sizing: :grid, max_hold_days: 20, buy_cost_rate: 0.0, sell_cost_rate: 0.0
    ).call

    assert_equal 2, result.trades.size
    assert result.trades.all? { |trade| trade.weight == Stock::StrategySimulation::BASE_WEIGHT }
    assert_equal 100_000.0, result.final_equity
  end

  test "rejects an unknown sizing mode" do
    error = assert_raises(ArgumentError) { Stock::StrategySimulation.new(Stock::SZSTK, sizing: :martingale) }

    assert_match(/martingale/, error.message)
  end

  test "reports not ready when there is no signal history" do    result = Stock::StrategySimulation.new(Stock::SZSTK).call

    refute result.ready
    assert_equal 0, result.dates
  end

  test "withholds results until the same minimum date count as SignalPerformance" do
    (Stock::StrategySimulation::MINIMUM_DATES - 1).times do |index|
      snapshot(stock: "sz000001", date: Date.new(2026, 1, 1) + index, price: 10.0, year_signal: "BUY5", lohas_signal: "BUY5")
    end

    result = Stock::StrategySimulation.new(Stock::SZSTK).call

    refute result.ready
    assert_equal Stock::StrategySimulation::MINIMUM_DATES - 1, result.dates
  end

  # The account is measured on the prices a shareholder would have seen: a
  # ten-for-ten bonus halves the quote and doubles what the share is worth.
  test "books the return a shareholder would have seen across an ex-rights date" do
    dates = 22.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      signals = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      snapshot(stock: "sz000001", date: date, price: index < 3 ? 10.0 : 5.0,
                             year_signal: signals[0], lohas_signal: signals[1])
    end
    StockCorporateAction.create!(
      area: Stock::SZSTK, stock: "sz000001", ex_date: dates[3],
      category: Stock::TdxQuote::CATEGORY_EX_RIGHTS, cash: 0.0, bonus: 10.0,
      rights: 0.0, rights_price: 0.0, resize: 0.0, factor: 2.0, fetched_at: Time.current
    )

    result = Stock::StrategySimulation.new(Stock::SZSTK, buy_cost_rate: 0.0, sell_cost_rate: 0.0).call

    trade = result.trades.first
    assert_equal dates[1], trade.entry_date
    assert_in_delta 10.0, trade.entry_price, 1e-9
    assert_in_delta 10.0, trade.exit_price, 1e-9
    assert_equal 0.0, trade.return_pct
  end

  # The same account measured on the raw closes the signals come from.
  test "can simulate the same account on raw closes" do
    dates = 22.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      signals = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      snapshot(stock: "sz000001", date: date, price: index < 3 ? 10.0 : 5.0,
                             year_signal: signals[0], lohas_signal: signals[1])
    end
    StockCorporateAction.create!(
      area: Stock::SZSTK, stock: "sz000001", ex_date: dates[3],
      category: Stock::TdxQuote::CATEGORY_EX_RIGHTS, cash: 0.0, bonus: 10.0,
      rights: 0.0, rights_price: 0.0, resize: 0.0, factor: 2.0, fetched_at: Time.current
    )

    adjusted = Stock::StrategySimulation.new(Stock::SZSTK, buy_cost_rate: 0.0, sell_cost_rate: 0.0, adjusted: true).call
    raw = Stock::StrategySimulation.new(Stock::SZSTK, buy_cost_rate: 0.0, sell_cost_rate: 0.0, adjusted: false).call

    assert_equal 0.0, adjusted.trades.first.return_pct
    assert_operator raw.trades.first.return_pct, :<, -40.0
  end

  # An account cannot un-buy a position, so a trade that covers a flagged day
  # is kept but counted: the number is reported rather than hidden.
  test "counts the trades whose holding period covers a flagged day" do
    dates = 22.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      signals = index.zero? ? ["BUY5", "BUY5"] : ["WAT9", "WAT9"]
      snapshot(stock: "sz000001", date: date, price: 10.0, year_signal: signals[0], lohas_signal: signals[1])
    end
    StockPriceAnomaly.create!(
      area: Stock::SZSTK, stock: "sz000001", date: dates[5],
      change_pct: -50.0, limit_pct: 10.5, detected_at: Time.current
    )

    result = Stock::StrategySimulation.new(Stock::SZSTK).call

    assert_equal 1, result.trades.size
    assert_equal 1, result.anomalous_trades
  end
end
