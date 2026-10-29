require "test_helper"

class PortfolioTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "portfolio.json")
  end

  teardown { FileUtils.remove_entry(@dir) }

  # Targets 40/50/10; `holdings` maps a bucket to the amount held in it.
  def portfolio(holdings = {})
    p = Portfolio.new(@path, { "targets" => { "cash" => 40, "bond" => 50, "stock" => 10 } })
    holdings.each { |bucket, amount| p.add_holding(name: bucket.to_s, code: "", bucket: bucket.to_s, amount: amount.to_s) }
    p
  end

  test "an empty file starts from the default mix and needs nothing" do
    p = Portfolio.load(@path)

    assert_equal Portfolio::DEFAULT_TARGETS, p.targets
    assert p.empty?
    assert_not p.needs_rebalance?
    assert_not File.exist?(@path), "loading must not create the file"
  end

  test "the mix compares each bucket with its target and prices the trade back" do
    p = portfolio(cash: 30_000, bond: 50_000, stock: 20_000)
    rows = p.rows.index_by(&:bucket)

    assert_equal 100_000, p.total
    assert_in_delta 30.0, rows["cash"].actual
    assert_in_delta(-10.0, rows["cash"].gap)
    assert_equal 10_000, rows["cash"].trade
    assert_equal 0, rows["bond"].trade
    assert_equal(-10_000, rows["stock"].trade)
    assert p.drifted?
  end

  test "drift inside the band is left alone" do
    p = portfolio(cash: 37_000, bond: 53_000, stock: 10_000)

    assert_not p.drifted?
    assert_not p.needs_rebalance?
  end

  test "a rebalance falls due one interval after the last one" do
    p = portfolio(cash: 40_000, bond: 50_000, stock: 10_000)
    p.record_rebalance(Date.new(2025, 11, 1))

    assert_equal Date.new(2026, 11, 1), p.due_on
    assert_not p.overdue?(Date.new(2026, 10, 31))
    assert p.overdue?(Date.new(2026, 11, 1))
  end

  test "new money fills the buckets short of target before anything else" do
    p = portfolio(cash: 30_000, bond: 50_000, stock: 20_000)

    # after 5 000: total 105 000, targets 42 000 / 52 500 / 10 500
    # short 12 000 and 2 500, stock is over: 5 000 shared 12:2.5
    assert_equal({ "cash" => 4_138, "bond" => 862, "stock" => 0 }, p.split("5000"))
  end

  test "money beyond every shortfall is split at the target weights" do
    p = portfolio(cash: 40_000, bond: 50_000, stock: 10_000)

    assert_equal({ "cash" => 4_000, "bond" => 5_000, "stock" => 1_000 }, p.split("10000"))
  end

  test "new money that only partly covers the shortfalls is shared by how short each is" do
    p = portfolio(cash: 20_000, bond: 40_000, stock: 40_000)
    # after 10 000: total 110 000, targets 44 000 / 55 000 / 11 000
    # short 24 000 and 15 000, stock is over: 10 000 shared 24:15
    split = p.split("10000")

    assert_equal 6_154, split["cash"]
    assert_equal 3_846, split["bond"]
    assert_equal 0, split["stock"]
  end

  test "a split needs a positive amount" do
    assert_raises(Portfolio::Invalid) { portfolio.split("0") }
    assert_raises(Portfolio::Invalid) { portfolio.split("abc") }
  end

  test "targets must be whole percentages adding up to 100" do
    p = portfolio

    assert_raises(Portfolio::Invalid) { p.update_settings(targets: { "cash" => "50", "bond" => "40", "stock" => "20" }, band: "5", interval: "12") }
    assert_raises(Portfolio::Invalid) { p.update_settings(targets: { "cash" => "x", "bond" => "40", "stock" => "60" }, band: "5", interval: "12") }
    assert_raises(Portfolio::Invalid) { p.update_settings(targets: { "cash" => "50", "bond" => "50", "stock" => "0" }, band: "0", interval: "12") }

    p.update_settings(targets: { "cash" => "50", "bond" => "50", "stock" => "0" }, band: "3", interval: "6")
    reloaded = Portfolio.load(@path)
    assert_equal({ "cash" => 50, "bond" => 50, "stock" => 0 }, reloaded.targets)
    assert_equal 3, reloaded.band
    assert_equal 6, reloaded.interval
  end

  test "holdings keep exact amounts and the date they were last updated" do
    p = portfolio
    p.add_holding(name: "余额宝", code: "", bucket: "cash", amount: "12,345.678", today: Date.new(2026, 10, 1))

    h = Portfolio.load(@path).holdings.first
    assert_equal "余额宝", h.name
    assert_nil h.code
    assert_equal BigDecimal("12345.68"), h.amount
    assert_equal Date.new(2026, 10, 1), h.updated_on

    p.update_holding(h.id, name: "余额宝", code: "", bucket: "cash", amount: "13000", today: Date.new(2026, 10, 29))
    assert_equal BigDecimal("13000"), Portfolio.load(@path).holdings.first.amount
  end

  test "a holding not updated for a month is flagged as stale" do
    p = portfolio
    p.add_holding(name: "old", code: "", bucket: "bond", amount: "1", today: Date.new(2026, 9, 1))
    p.add_holding(name: "new", code: "", bucket: "bond", amount: "1", today: Date.new(2026, 10, 20))

    assert_equal ["old"], p.stale_holdings(Date.new(2026, 10, 29)).map(&:name)
  end

  test "bad holdings are refused" do
    p = portfolio

    assert_raises(Portfolio::Invalid) { p.add_holding(name: "", code: "", bucket: "cash", amount: "1") }
    assert_raises(Portfolio::Invalid) { p.add_holding(name: "x", code: "", bucket: "gold", amount: "1") }
    assert_raises(Portfolio::Invalid) { p.add_holding(name: "x", code: "", bucket: "cash", amount: "-1") }
    assert_raises(Portfolio::Invalid) { p.add_holding(name: "x", code: "", bucket: "cash", amount: "lots") }
    assert_raises(Portfolio::Invalid) { p.remove_holding("missing") }
  end

  test "maturities list term holdings soonest first and flag what is due or past" do
    p = portfolio
    today = Date.new(2026, 10, 29)
    p.add_holding(name: "6m", code: "", bucket: "cash", amount: "250000", institution: "B", matures_on: "2027-04-29")
    p.add_holding(name: "3m", code: "", bucket: "cash", amount: "250000", institution: "C", matures_on: "2026-11-03")
    p.add_holding(name: "old", code: "", bucket: "bond", amount: "1000", matures_on: "2026-10-01")
    p.add_holding(name: "fund", code: "", bucket: "cash", amount: "200000")

    reloaded = Portfolio.load(@path)
    assert_equal %w[old 3m 6m], reloaded.maturities.map(&:name)
    assert_equal ["3m"], reloaded.due_soon(today).map(&:name)
    assert_equal ["old"], reloaded.matured(today).map(&:name)
    assert_equal 5, reloaded.holdings.find { |h| h.name == "3m" }.days_left(today)
    assert_equal "C", reloaded.holdings.find { |h| h.name == "3m" }.institution
  end

  test "more than deposit insurance covers at one bank is flagged" do
    p = portfolio
    p.add_holding(name: "a", code: "", bucket: "cash", amount: "300000", institution: "A")
    p.add_holding(name: "b", code: "", bucket: "bond", amount: "200000", institution: "A")
    p.add_holding(name: "c", code: "", bucket: "cash", amount: "500000", institution: "B")
    assert_empty p.over_insured, "exactly the limit is covered"

    p.add_holding(name: "d", code: "", bucket: "cash", amount: "0.01", institution: "A")
    assert_equal ["A"], p.over_insured.keys
    assert_equal BigDecimal("500000.01"), p.over_insured["A"]
  end

  test "a maturity date must be a real date or left empty" do
    p = portfolio

    assert_raises(Portfolio::Invalid) { p.add_holding(name: "x", code: "", bucket: "cash", amount: "1", matures_on: "2026-13-40") }
    p.add_holding(name: "x", code: "", bucket: "cash", amount: "1", matures_on: "", institution: " ")
    assert_nil p.holdings.last.matures_on
    assert_nil p.holdings.last.institution
  end

  test "files saved before maturities existed still load" do
    File.write(@path, JSON.generate({ "holdings" => [{ "id" => "x", "name" => "old", "bucket" => "cash", "amount" => "5", "updated_on" => "2026-10-01" }] }))

    h = Portfolio.load(@path).holdings.first
    assert_nil h.matures_on
    assert_nil h.institution
  end

  test "saving replaces the file whole and leaves no temporary files" do
    portfolio(cash: 1)

    assert_equal ["portfolio.json"], Dir.children(@dir)
    assert_equal 1, JSON.parse(File.read(@path))["holdings"].size
  end
end
