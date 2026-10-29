require "test_helper"

class DcaTrackerTest < ActiveSupport::TestCase
  # TongdaXin stores fund prices at 1/1000 yuan; the fixture writes
  # close x 100, so 40.0 here is a 4.000 yuan ETF.
  ROWS = [
    [Date.new(2026, 1, 9), 40.0],
    [Date.new(2026, 1, 12), 40.0],
    [Date.new(2026, 2, 10), 44.0],
    [Date.new(2026, 3, 10), 50.0]
  ].freeze
  NET = 1000 * (1 - 0.0012)

  def plan(**overrides)
    Portfolio::Plan.new(id: "p", name: "CSI 300", fund_code: "110020", proxy: "sh510310",
                        amount: BigDecimal("1000"), day: 10, start_on: Date.new(2026, 1, 10), months: 4,
                        **overrides)
  end

  def track(plan, events: nil, today: Date.new(2026, 3, 20))
    Dir.mktmpdir do |root|
      write_day_file(root, "sh", "sh510310", ROWS)
      with_data_root(root) { DcaTracker.new(plan, events: events, today: today).call }
    end
  end

  test "each month buys at the first close on or after its date, after the fee" do
    r = track(plan)

    assert_equal [Date.new(2026, 1, 12), Date.new(2026, 2, 10), Date.new(2026, 3, 10)], r.purchases.map(&:date)
    assert_equal 3000, r.invested
    assert_in_delta (NET / 4.0 + NET / 4.4 + NET / 5.0) * 5.0, r.value.to_f, 0.01
    assert_equal Date.new(2026, 3, 10), r.as_of
    assert_equal Date.new(2026, 4, 10), r.next_date
    assert_not r.done
    assert_not r.adjusted
  end

  test "the deposit comparison earns simple interest from each purchase" do
    r = track(plan)

    # 57 and 28 days at 1.5% a year on two of the three purchases
    assert_in_delta 3000 + 1000 * 0.015 * (57 + 28) / 365.0, r.deposit_value.to_f, 0.01
    assert_in_delta r.value.to_f - r.deposit_value.to_f, r.versus_deposit.to_f, 0.001
  end

  test "a dividend is reinvested: earlier units grow by it, later ones do not" do
    dividend = { date: Date.new(2026, 3, 10), category: 1, cash: 2.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 0.0 }
    r = track(plan, events: [dividend])

    # 0.2 yuan a unit off a 4.4 close: the reference price is 4.2, so units
    # held through it are worth 4.4 / 4.2 more than the raw close says.
    expected = (NET / 4.0 + NET / 4.4) * 5.0 * (4.4 / 4.2) + NET
    assert_in_delta expected, r.value.to_f, 0.01
    assert r.adjusted
  end

  test "records not fetched yet differ from an ETF that never paid" do
    assert_not track(plan).adjusted, "nothing fetched: dividends are not counted"
    assert track(plan, events: []).adjusted, "fetched, none paid: nothing is missing"
    assert_equal track(plan).value, track(plan, events: []).value
  end

  test "the TongdaXin duplicate of a record is applied once" do
    dividend = { date: Date.new(2026, 3, 10), category: 1, cash: 2.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 0.0 }

    assert_equal track(plan, events: [dividend]).value, track(plan, events: [dividend, dividend.dup]).value
  end

  test "a plan that has not started yet has bought nothing" do
    r = track(plan(start_on: Date.new(2026, 4, 1)))

    assert_empty r.purchases
    assert_equal 0, r.invested
    assert_equal Date.new(2026, 4, 10), r.next_date
  end

  test "a plan stops after its last month" do
    r = track(plan(months: 2))

    assert_equal 2, r.purchases.size
    assert r.done
    assert_nil r.next_date
  end

  test "a date past the last close waits for the data" do
    r = track(plan, today: Date.new(2026, 4, 15))

    assert_equal 3, r.purchases.size
    assert_equal Date.new(2026, 4, 10), r.next_date
  end

  test "a code with no price file says so" do
    r = track(plan(proxy: "sh599999"))

    assert_not r.priced
    assert_empty r.purchases
  end

  test "a plan starting before the ETF listed is not priced from a later close" do
    r = track(plan(start_on: Date.new(2025, 12, 10)))

    assert r.too_early
    assert_empty r.purchases
  end

  test "hindsight replays the plan from each horizon the history reaches" do
    today = Date.new(2026, 3, 20)
    past = Dir.mktmpdir do |root|
      write_day_file(root, "sh", "sh510310", ROWS)
      with_data_root(root) { DcaTracker.hindsight(plan(start_on: Date.new(2026, 11, 10)), today: today, years: [1, 3]) }
    end

    # one year back starts in March 2025, before the fixture's first close
    assert_nil past[1]
    assert_nil past[3]

    mine = plan(months: 4)
    recent = Dir.mktmpdir do |root|
      rows = [[Date.new(2025, 3, 10), 30.0]] + ROWS
      write_day_file(root, "sh", "sh510310", rows)
      with_data_root(root) { DcaTracker.hindsight(mine, today: today, years: [1]) }
    end

    r = recent[1]
    assert_equal Date.new(2025, 3, 10), r.purchases.first.date
    # twelve monthly purchases; the fixture has no closes from April to
    # December, so those months buy at the first close after them
    assert_equal 12, r.purchases.size
    assert_equal 4, mine.months, "the reader's own plan is left as it was"
    assert_equal Date.new(2026, 1, 10), mine.start_on
  end

  test "codes are read the way people type them" do
    assert_equal "sh510310", DcaTracker.normalize("510310")
    assert_equal "sz159919", DcaTracker.normalize(" 159919 ")
    assert_equal "sh512050", DcaTracker.normalize("SH512050")
    assert_nil DcaTracker.normalize("110020")
    assert_nil DcaTracker.normalize("abc")
  end
end
