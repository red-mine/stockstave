require "test_helper"

class StockSignalPerformanceTest < ActiveSupport::TestCase
  test "measures only forward outcomes for buy-signal cohorts" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    5.times do |stock_index|
      dates.each_with_index do |date, date_index|
        direction = stock_index < 3 ? 1.0 : -0.5
        StockSignalSnapshot.create!(
          stock: format("sz%06d", stock_index), area: Stock::SZSTK,
          signal_date: date, price: 100 + direction * date_index,
          year_signal: "BUY5", lohas_signal: "BUY5"
        )
      end
    end
    dates.each_with_index do |date, date_index|
      StockSignalSnapshot.create!(
        stock: "sz999999", area: Stock::SZSTK, signal_date: date,
        price: 100 - date_index, year_signal: "SEL7", lohas_signal: "SEL7"
      )
    end

    report = Stock::SignalPerformance.new(Stock::SZSTK, horizon: 5).call

    assert report.ready
    assert_equal 20, report.dates
    assert_equal 1, report.cohorts.size
    cohort = report.cohorts.first
    assert_equal ["BUY5", "BUY5"], [cohort.year_signal, cohort.lohas_signal]
    # Entry is the close after the signal date and exit is five trading days
    # after that, so the last usable signal date is five days before the end
    # of the series: 14 dates, not 15.
    assert_equal 70, cohort.sample_size
    assert_equal 60.0, cohort.win_rate
    assert_operator cohort.average_return, :>, 0
    assert_operator cohort.average_drawdown, :<, 0
  end

  test "sorts tied cohorts that mix a missing signal code with a present one" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }

    5.times do |stock_index|
      dates.each_with_index do |date, date_index|
        StockSignalSnapshot.create!(
          stock: format("sza%06d", stock_index), area: Stock::SZSTK,
          signal_date: date, price: 100 - date_index,
          year_signal: nil, lohas_signal: "SEL7"
        )
      end
    end
    5.times do |stock_index|
      dates.each_with_index do |date, date_index|
        StockSignalSnapshot.create!(
          stock: format("szb%06d", stock_index), area: Stock::SZSTK,
          signal_date: date, price: 100 - date_index,
          year_signal: "SEL3", lohas_signal: nil
        )
      end
    end

    report = Stock::SignalPerformance.new(Stock::SZSTK, horizon: 5).call(signal_type: :sell)

    assert report.ready
    assert_equal 2, report.cohorts.size
    assert_equal [70, 70], report.cohorts.map(&:sample_size)
  end

  # trend_group is the only caller of the slope bands here, and it is reached
  # just by passing group_by_trend. It used to keep its own copy of those
  # thresholds, so this pins it to whatever Stock::Trend now says.
  test "groups cohorts by the shared trend bands" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    slopes = {
      "sza000000" => [0.03, 0.03],    # both uptrend -> uptrend
      "szb000000" => [0.03, -0.05],   # disagree     -> mixed
      "szc000000" => [nil, nil]       # neither      -> unknown
    }

    slopes.each do |stock, (year_trend, long_trend)|
      dates.each do |date|
        StockSignalSnapshot.create!(
          stock: stock, area: Stock::SZSTK, signal_date: date, price: 10.0,
          year_signal: "BUY5", lohas_signal: "BUY5",
          year_trend: year_trend, long_trend: long_trend
        )
      end
    end

    report = Stock::SignalPerformance.new(Stock::SZSTK).call(group_by_trend: true)

    assert report.ready
    assert_equal ["mixed", "unknown", "uptrend"], report.cohorts.map(&:trend_group).sort
    assert_equal [14, 14, 14], report.cohorts.map(&:sample_size)
  end

  # CHP0 counts as a buy signal only because SignalFamily lists it. This pins
  # the report to that list rather than to a private copy: remove CHP0 from
  # SignalFamily::BUY and this stops finding the cohort.
  test "counts a signal as buy because SignalFamily lists it" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each do |date|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK, signal_date: date, price: 10.0,
        year_signal: "CHP0", lohas_signal: "CHP0"
      )
    end

    report = Stock::SignalPerformance.new(Stock::SZSTK).call

    assert report.ready
    assert_equal [["CHP0", "CHP0"]], report.cohorts.map { |cohort| [cohort.year_signal, cohort.lohas_signal] }
  end

  test "withholds results until twenty distinct market dates exist" do
    19.times do |index|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK,
        signal_date: Date.new(2026, 1, 1) + index, price: 10 + index,
        year_signal: "BUY5", lohas_signal: "BUY5"
      )
    end

    report = Stock::SignalPerformance.new(Stock::SZSTK).call

    refute report.ready
    assert_empty report.cohorts
  end

  # A signal is derived from a close, so that close is not tradable. This
  # pins the entry to the close after the signal date: under the old
  # signal-day-close entry the jump below landed inside the measured return.
  test "enters at the close after the signal date" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK, signal_date: date,
        price: index.zero? ? 100.0 : 200.0,
        year_signal: "BUY5", lohas_signal: "BUY5"
      )
    end

    report = Stock::SignalPerformance.new(Stock::SZSTK, horizon: 5).call

    assert report.ready
    cohort = report.cohorts.first
    assert_equal 0.0, cohort.average_return
    assert_equal 0.0, cohort.average_drawdown
  end

  # A cohort that rises with the market has not earned anything: the event
  # study measures excess against the stocks the strategy could have picked
  # that day. This cohort rises, but less than its own model pool.
  test "measures excess against the same-day model pool" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK, signal_date: date,
        price: 100 * 1.02**index,
        year_signal: "BUY5", lohas_signal: "BUY5"
      )
      24.times do |pool_index|
        StockSignalSnapshot.create!(
          stock: format("sz%06d", pool_index + 100), area: Stock::SZSTK,
          signal_date: date, price: 100 * 1.1**index
        )
      end
    end

    report = Stock::SignalPerformance.new(Stock::SZSTK, horizon: 5).call

    assert report.ready
    cohort = report.cohorts.first
    assert_operator cohort.average_return, :>, 0
    assert_operator cohort.baseline_return, :>, cohort.average_return
    assert_operator cohort.excess_return, :<, 0
    assert_in_delta cohort.average_return - cohort.baseline_return, cohort.excess_return, 0.02
    assert_equal 14, cohort.excess_dates
    assert_equal 14, report.baseline.dates
  end

  # The baseline needs enough stocks to mean anything. The event study draws
  # the same line at 20; below it the page shows the absolute numbers only.
  test "withholds the baseline when the model pool is too small" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      6.times do |stock_index|
        StockSignalSnapshot.create!(
          stock: format("sz%06d", stock_index), area: Stock::SZSTK,
          signal_date: date, price: 100 * 1.1**index,
          year_signal: stock_index.zero? ? "BUY5" : nil,
          lohas_signal: stock_index.zero? ? "BUY5" : nil
        )
      end
    end

    report = Stock::SignalPerformance.new(Stock::SZSTK, horizon: 5).call

    assert report.ready
    cohort = report.cohorts.first
    assert_nil cohort.baseline_return
    assert_nil cohort.excess_return
    assert_equal 0, cohort.excess_dates
    assert_nil report.baseline.average_return
    assert_equal 0, report.baseline.dates
  end

  # A holding period that spans an ex-rights date shows a price drop that a
  # shareholder did not suffer: the ten-for-ten bonus halves the quote and
  # doubles what a share is worth. The report measures on the adjusted
  # prices, the way the event study does.
  test "measures returns on the prices a shareholder would have seen" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each_with_index do |date, index|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK, signal_date: date,
        price: index < 5 ? 100.0 : 50.0,
        year_signal: "BUY5", lohas_signal: "BUY5"
      )
    end

    raw = Stock::SignalPerformance.new(Stock::SZSTK, horizon: 5).call
    # 14 signal dates leave a full window; four of them enter before the
    # bonus and leave after it, so the raw price halves under them.
    assert_in_delta(-14.29, raw.cohorts.first.average_return, 0.005)

    StockCorporateAction.create!(
      area: Stock::SZSTK, stock: "sz000001", ex_date: dates[5],
      category: Stock::TdxQuote::CATEGORY_EX_RIGHTS, cash: 0.0, bonus: 10.0,
      rights: 0.0, rights_price: 0.0, resize: 0.0, factor: 2.0, fetched_at: Time.current
    )

    adjusted = Stock::SignalPerformance.new(Stock::SZSTK, horizon: 5).call

    assert_in_delta 0.0, adjusted.cohorts.first.average_return, 1e-9
    assert_in_delta 0.0, adjusted.cohorts.first.average_drawdown, 1e-9
  end

  # A day whose adjusted move no board would allow means a factor is wrong,
  # so the return across it is not a number anyone should act on. The event
  # study drops the same windows.
  test "drops a holding period that covers a day whose adjusted move no board allows" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each do |date|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK, signal_date: date, price: 100.0,
        year_signal: "BUY5", lohas_signal: "BUY5"
      )
    end
    StockPriceAnomaly.create!(
      area: Stock::SZSTK, stock: "sz000001", date: dates[3],
      change_pct: -50.0, limit_pct: 10.5, detected_at: Time.current
    )

    report = Stock::SignalPerformance.new(Stock::SZSTK, horizon: 5).call

    # 14 signal dates leave a full window, and three of their windows cover
    # the flagged day.
    assert_equal 11, report.cohorts.first.sample_size
  end
end
