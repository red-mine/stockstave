require "test_helper"

class MonthlyChecklistTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 30)

  setup do
    @dir = Dir.mktmpdir
    @portfolio = Portfolio.new(File.join(@dir, "portfolio.json"),
                               { "targets" => { "cash" => "50", "bond" => "50", "stock" => "0" } })
  end

  teardown { FileUtils.remove_entry(@dir) }

  # A tracker result stub: only the fields the checklist reads.
  def result(next_date: nil, done: false) = Struct.new(:next_date, :done).new(next_date, done)

  def plan(name: "沪深300", amount: 4200, fund_code: "110020")
    Portfolio::Plan.new(id: name, name: name, fund_code: fund_code, proxy: "sh510310",
                        amount: BigDecimal(amount.to_s), day: 10, start_on: TODAY, months: 12)
  end

  def checklist(tracked: [], fund_data: nil)
    @portfolio.plans.replace(tracked.map(&:first))
    MonthlyChecklist.new(@portfolio, today: TODAY, fund_data: fund_data, tracked: tracked)
  end

  def keys(c) = c.items.map(&:key)

  test "an empty portfolio with nothing due is a quiet month" do
    c = checklist

    assert_empty c.actions
    assert_nil c.next_event
  end

  test "a debit within the month is listed, with the cash to keep, debit first" do
    c = checklist(tracked: [[plan, result(next_date: Date.new(2026, 11, 10))],
                            [plan(name: "A500", amount: 1400), result(next_date: Date.new(2026, 11, 10))]])

    assert_equal %i[debit debit keep_cash], c.actions.map(&:key)
    assert_equal 5600, c.actions.last.args[:amount]
  end

  test "a debit just past still shows until the prices record it" do
    c = checklist(tracked: [[plan, result(next_date: Date.new(2026, 10, 27))]])

    assert_includes keys(c), :debit
  end

  test "a debit beyond the month is the next event, not an action" do
    c = checklist(tracked: [[plan, result(next_date: Date.new(2026, 12, 10))]])

    assert_empty c.actions
    assert_equal Date.new(2026, 12, 10), c.next_event
  end

  test "maturing and matured deposits are actions" do
    @portfolio.add_holding(name: "3个月定期", code: "", bucket: "bond", amount: "250000", institution: "B",
                           matures_on: "2026-11-15", today: TODAY)
    @portfolio.add_holding(name: "旧定期", code: "", bucket: "bond", amount: "1000", matures_on: "2026-10-01", today: TODAY)
    @portfolio.add_holding(name: "5年国债", code: "", bucket: "bond", amount: "1", matures_on: "2031-10-30", today: TODAY)
    c = checklist

    assert_equal %i[matured maturing], c.actions.map(&:key).first(2)
    assert_equal Date.new(2031, 10, 30), c.next_event
  end

  test "drift, stale amounts and deposits over insurance are actions" do
    @portfolio.add_holding(name: "活期", code: "", bucket: "cash", amount: "600000", institution: "A", today: TODAY - 60)
    c = checklist

    assert_includes keys(c), :rebalance
    assert_includes keys(c), :stale
    assert_includes keys(c), :over_insured
  end

  test "a mix on target is a fine check" do
    @portfolio.add_holding(name: "活期", code: "", bucket: "cash", amount: "500", today: TODAY)
    @portfolio.add_holding(name: "短债", code: "", bucket: "bond", amount: "500", today: TODAY)

    assert_equal [:on_target], checklist.items.map(&:key)
  end

  test "the funds being bought are checked again against the fund data" do
    fund = Struct.new(:name).new("易方达沪深300ETF联接A")
    reason = FundCheck::Reason.new(verdict: :caution, key: :restricted, args: { status: "暂停申购" })
    data = Object.new
    data.define_singleton_method(:available?) { true }
    data.define_singleton_method(:details_at) { TODAY.iso8601 }
    data.define_singleton_method(:find) { |code| code == "110020" ? fund : nil }
    verdict = :good
    data.define_singleton_method(:check) { |_f| Struct.new(:verdict, :reasons).new(verdict, [reason]) }

    assert_includes keys(checklist(tracked: [[plan, result]], fund_data: data)), :fund_good

    verdict = :caution
    flagged = checklist(tracked: [[plan, result]], fund_data: data).actions.find { |i| i.key == :fund_flagged }
    assert_equal :restricted, flagged.args[:reason].key
  end

  test "old fund data is flagged once there are plans to check" do
    data = Struct.new(:available?, :details_at).new(false, "2026-10-01T00:00:00+08:00")

    assert_includes keys(checklist(tracked: [[plan, result]], fund_data: data)), :fund_data_old
    assert_not_includes keys(checklist(fund_data: data)), :fund_data_old
  end
end
