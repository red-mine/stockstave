require "test_helper"

class Stock::PriceAdjustmentTest < ActiveSupport::TestCase
  # A ten-for-ten bonus share: the close before the ex-date was 10, the close
  # on it is 5, and the reference price the event leaves behind is
  # (10 * 10) / (10 + 10) = 5. The shareholder kept the same value, so the
  # factor doubles and the adjusted series stays flat across the ex-date.
  def ex_rights_event(date:, cash: 0.0, bonus: 10.0, rights: 0.0, rights_price: 0.0)
    {
      date: date, category: Stock::TdxQuote::CATEGORY_EX_RIGHTS,
      cash: cash, bonus: bonus, rights: rights, rights_price: rights_price, resize: 0.0
    }
  end

  test "computes the factor the way the event study does" do
    dates = [Date.new(2026, 1, 5), Date.new(2026, 1, 6), Date.new(2026, 1, 7)]
    closes = [[dates[0], 10.0], [dates[1], 5.0], [dates[2], 5.0]]

    factors = Stock::PriceAdjustment.factors_for_events([ex_rights_event(date: dates[1])], closes)

    assert_equal({ dates[1] => 2.0 }, factors)
  end

  test "a cash dividend is taken out of the reference price" do
    dates = [Date.new(2026, 1, 5), Date.new(2026, 1, 6)]
    closes = [[dates[0], 10.0], [dates[1], 9.0]]

    factors = Stock::PriceAdjustment.factors_for_events(
      [ex_rights_event(date: dates[1], cash: 1.0, bonus: 0.0)], closes
    )

    # ref = (10 * 10 - 1) / 10 = 9.9, so the factor is 10 / 9.9.
    assert_in_delta 10.0 / 9.9, factors[dates[1]], 1e-12
  end

  test "a share split divides the reference price" do
    dates = [Date.new(2026, 1, 5), Date.new(2026, 1, 6)]
    closes = [[dates[0], 10.0], [dates[1], 5.0]]
    event = {
      date: dates[1], category: Stock::TdxQuote::CATEGORY_RESIZE,
      cash: 0.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 2.0
    }

    factors = Stock::PriceAdjustment.factors_for_events([event], closes)

    assert_equal({ dates[1] => 2.0 }, factors)
  end

  test "an event that happened before the series started cannot change a return inside it" do
    dates = [Date.new(2026, 1, 5), Date.new(2026, 1, 6)]
    closes = [[dates[0], 10.0], [dates[1], 10.0]]
    event = ex_rights_event(date: Date.new(2020, 6, 1))

    factors = Stock::PriceAdjustment.factors_for_events([event], closes)

    # The factor in force back then was still 1.0, so the series inside the
    # window is untouched -- the same rule the event study applies.
    assert_equal({ Date.new(2020, 6, 1) => 1.0 }, factors)
  end

  test "the factor is in force from the ex-date itself" do
    dates = [Date.new(2026, 1, 5), Date.new(2026, 1, 6)]
    factors = Stock::PriceAdjustment::Factors.new(
      [Stock::PriceAdjustment::Event.new(stock: "sz000001", ex_date: dates[1], factor: 2.0)]
    )

    assert_equal 1.0, factors.factor_for("sz000001", dates[0])
    assert_equal 2.0, factors.factor_for("sz000001", dates[1])
    assert_equal 2.0, factors.factor_for("sz000001", Date.new(2026, 6, 1))
    assert_equal 1.0, factors.factor_for("sz000002", dates[1])
  end

  test "the adjusted price is the raw close times the factor in force" do
    factors = Stock::PriceAdjustment::Factors.new(
      [Stock::PriceAdjustment::Event.new(stock: "sz000001", ex_date: Date.new(2026, 1, 6), factor: 2.0)]
    )

    assert_in_delta 10.0, factors.price("sz000001", Date.new(2026, 1, 5), 10.0), 1e-12
    assert_in_delta 10.0, factors.price("sz000001", Date.new(2026, 1, 6), 5.0), 1e-12
  end

  test "a factor set that moves no price is not adjusted" do
    factors = Stock::PriceAdjustment::Factors.new(
      [Stock::PriceAdjustment::Event.new(stock: "sz000001", ex_date: Date.new(2026, 1, 6), factor: 1.0)]
    )

    refute factors.adjusted?
    assert Stock::PriceAdjustment::Factors.new([]).adjusted? == false
  end

  test "an adjusted price series is not adjusted without a factor" do
    factors = Stock::PriceAdjustment::Factors.new([])

    refute factors.adjusted?
  end

  test "flags an adjusted move no board would allow" do
    series = [
      [Date.new(2026, 1, 5), 10.0],
      [Date.new(2026, 1, 6), 5.0]
    ]

    anomalies = Stock::PriceAdjustment.impossible_days("sz000001", series, Date.new(2026, 1, 5))

    assert_equal 1, anomalies.size
    assert_equal Date.new(2026, 1, 6), anomalies.first[:date]
    assert_in_delta -50.0, anomalies.first[:change_pct], 1e-9
    assert_in_delta 10.5, anomalies.first[:limit_pct], 1e-9
  end

  test "each board is held to its own daily limit" do
    series = [
      [Date.new(2026, 1, 5), 10.0],
      [Date.new(2026, 1, 6), 10.0 * 0.85]
    ]

    assert_equal 1, Stock::PriceAdjustment.impossible_days("sz000001", series, Date.new(2026, 1, 5)).size
    assert_empty Stock::PriceAdjustment.impossible_days("sz300001", series, Date.new(2026, 1, 5))
    assert_empty Stock::PriceAdjustment.impossible_days("bj920001", series, Date.new(2026, 1, 5))
  end

  # The expected series below was produced by the event study's own adjust()
  # (research/event_study/fetch_xdxr.py) for the same closes and the same
  # events, so this pins the app's arithmetic to the study's rather than to
  # itself.
  test "adjusts a series exactly the way the event study does" do
    closes = [
      [Date.new(2026, 1, 5), 10.0], [Date.new(2026, 1, 6), 10.2], [Date.new(2026, 1, 7), 10.5],
      [Date.new(2026, 1, 8), 5.25], [Date.new(2026, 1, 9), 5.3], [Date.new(2026, 1, 12), 5.4],
      [Date.new(2026, 1, 13), 5.25], [Date.new(2026, 1, 14), 2.65], [Date.new(2026, 1, 15), 2.7],
      [Date.new(2026, 1, 16), 2.8], [Date.new(2026, 1, 19), 2.75]
    ]
    events = [
      ex_rights_event(date: Date.new(2026, 1, 7), bonus: 10.0),
      ex_rights_event(date: Date.new(2026, 1, 13), cash: 0.5, bonus: 0.0),
      { date: Date.new(2026, 1, 15), category: Stock::TdxQuote::CATEGORY_RESIZE,
        cash: 0.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 2.0 }
    ]
    expected = [
      10.0, 10.2, 21.0, 10.5, 10.6, 10.8, 10.598130841121497, 5.349532710280374,
      10.900934579439255, 11.304672897196262, 11.102803738317759
    ]

    factors = Stock::PriceAdjustment.factors_for_events(events, closes)
    lookup = Stock::PriceAdjustment::Factors.new(
      events.map do |event|
        Stock::PriceAdjustment::Event.new(
          stock: "sz000001", ex_date: event[:date], factor: factors.fetch(event[:date], 1.0)
        )
      end
    )

    closes.each_with_index do |(date, close), index|
      assert_in_delta expected[index], lookup.price("sz000001", date, close), 1e-12
    end
  end

  test "only A shares are judged by the daily limit" do
    series = [
      [Date.new(2026, 1, 5), 10.0],
      [Date.new(2026, 1, 6), 5.0]
    ]

    assert_equal 1, Stock::PriceAdjustment.impossible_days("sz000001", series, Date.new(2026, 1, 5)).size
    # A fund and a sector index have no daily price limit to be judged by.
    assert_empty Stock::PriceAdjustment.impossible_days("sh588170", series, Date.new(2026, 1, 5))
    assert_empty Stock::PriceAdjustment.impossible_days("sh880006", series, Date.new(2026, 1, 5))
  end

  test "a new listing is exempt from the daily limit for its first five sessions" do
    series = [
      [Date.new(2026, 2, 5), 10.0],
      [Date.new(2026, 2, 6), 5.0],
      [Date.new(2026, 2, 9), 5.0],
      [Date.new(2026, 2, 10), 5.0],
      [Date.new(2026, 2, 11), 5.0],
      [Date.new(2026, 2, 12), 5.0]
    ]

    late = Stock::PriceAdjustment.impossible_days("sz000001", series, Date.new(2026, 1, 5))
    early = Stock::PriceAdjustment.impossible_days("sz000001", series, Date.new(2026, 2, 5))

    assert_empty late
    assert_equal 1, early.size
    assert_equal Date.new(2026, 2, 6), early.first[:date]
  end
end
