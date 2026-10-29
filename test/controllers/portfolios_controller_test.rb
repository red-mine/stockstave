require "test_helper"

class PortfoliosControllerTest < ActionDispatch::IntegrationTest
  setup do
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "portfolio.json")
  end

  teardown { FileUtils.remove_entry(@dir) }

  def with_portfolio_file(&block)
    Portfolio.stub(:default_path, @path, &block)
  end

  test "an empty portfolio asks for holdings" do
    with_portfolio_file { get portfolio_path }

    assert_response :success
    assert_select "h1", text: "My allocation"
    assert_select ".portfolio-status.is-empty"
  end

  test "added holdings show the mix and the trades back to target" do
    with_portfolio_file do
      post portfolio_holdings_path, params: { holding: { name: "Money fund", code: "", bucket: "cash", amount: "30000" } }
      post portfolio_holdings_path, params: { holding: { name: "Bond fund", code: "511010", bucket: "bond", amount: "50000" } }
      post portfolio_holdings_path, params: { holding: { name: "CSI 300", code: "510300", bucket: "stock", amount: "20000" } }
      follow_redirect!
    end

    assert_response :success
    assert_select "#rebalance-status.is-action"
    assert_select "#mix-table tr[data-bucket=cash] .trade .buy", text: "Buy ¥10,000"
    assert_select "#mix-table tr[data-bucket=stock] .trade .sell", text: "Sell ¥10,000"
    assert_select "#holdings-table tbody tr", 3
  end

  test "new money is split toward the buckets that are short" do
    Portfolio.new(@path).tap do |p|
      p.add_holding(name: "a", code: "", bucket: "cash", amount: "30000")
      p.add_holding(name: "b", code: "", bucket: "bond", amount: "50000")
      p.add_holding(name: "c", code: "", bucket: "stock", amount: "20000")
    end

    with_portfolio_file { get portfolio_path, params: { new_money: "5,000" } }

    assert_select "#split-result li", 3
    assert_select "#split-result li:first-child strong", text: "¥4,138"
  end

  test "a bad amount to split is reported, not raised" do
    with_portfolio_file { get portfolio_path, params: { new_money: "abc" } }

    assert_response :success
    assert_select ".portfolio-flash.is-alert"
  end

  test "settings that do not add up are refused with a reason" do
    with_portfolio_file do
      patch portfolio_settings_path, params: { settings: { targets: { cash: "50", bond: "50", stock: "10" }, band: "5", interval: "12" } }
      follow_redirect!
    end

    assert_select ".portfolio-flash.is-alert", text: /add up to 100/
    assert_equal Portfolio::DEFAULT_TARGETS, Portfolio.load(@path).targets
  end

  test "holdings can be edited and removed, and a rebalance recorded" do
    p = Portfolio.new(@path)
    p.add_holding(name: "a", code: "", bucket: "cash", amount: "100")
    id = p.holdings.first.id

    with_portfolio_file do
      patch portfolio_holding_path(id), params: { holding: { name: "a", code: "", bucket: "bond", amount: "250" } }
      assert_equal "bond", Portfolio.load(@path).holdings.first.bucket

      post portfolio_rebalanced_path
      assert_equal Date.current, Portfolio.load(@path).last_rebalanced_on

      delete portfolio_holding_path(id)
      assert Portfolio.load(@path).empty?
    end
  end

  test "term holdings appear in the maturity list with a running total and alerts" do
    today = Date.current
    p = Portfolio.new(@path)
    p.add_holding(name: "Soon", code: "", bucket: "cash", amount: "250000", institution: "Bank B", matures_on: (today + 3).iso8601)
    p.add_holding(name: "Later", code: "", bucket: "cash", amount: "300000", institution: "Bank A", matures_on: (today + 90).iso8601)
    p.add_holding(name: "Also A", code: "", bucket: "bond", amount: "300000", institution: "Bank A")

    with_portfolio_file { get portfolio_path }

    assert_select "#maturity-table tbody tr", 2
    assert_select "#maturity-table tbody tr:first-child td:last-child", text: "¥250,000"
    assert_select "#maturity-table tbody tr:last-child td:last-child", text: "¥550,000"
    assert_select "#maturity-table tbody tr.is-due", 1
    assert_select "#due-status", text: /Soon/
    assert_select ".insured-status", 1
    assert_select ".insured-status", text: /Bank A holds ¥600,000/
  end

  test "a holding's bank and maturity are saved from the form" do
    with_portfolio_file do
      post portfolio_holdings_path, params: { holding: { name: "3m deposit", code: "", bucket: "cash", amount: "250000",
                                                         institution: "Bank B", matures_on: "2027-01-29" } }
    end

    h = Portfolio.load(@path).holdings.first
    assert_equal "Bank B", h.institution
    assert_equal Date.new(2027, 1, 29), h.matures_on
  end

  test "no maturity list without dated holdings" do
    Portfolio.new(@path).add_holding(name: "fund", code: "", bucket: "cash", amount: "1")

    with_portfolio_file { get portfolio_path }

    assert_select "#maturity-table", 0
  end

  class FakeFetcher
    def initialize(failures: {})
      @failures = failures
    end

    def call(codes, deadline: nil)
      Stock::CorporateActionFetcher::Result.new(events: codes.to_h { |c| [c, []] }.except(*@failures.keys),
                                                failures: @failures.slice(*codes))
    end
  end

  def with_etf_prices(fetcher: FakeFetcher.new, &block)
    Dir.mktmpdir do |root|
      today = Date.current
      write_day_file(root, "sh", "sh510310", [[today - 40, 40.0], [today - 10, 44.0], [today - 1, 50.0]])
      with_data_root(root) do
        # stub calls a value that responds to #call, so hand it a lambda
        Portfolio.stub(:events_fetcher, -> { fetcher }) { with_portfolio_file(&block) }
      end
    end
  end

  test "an auto-investment plan is added and valued on its ETF" do
    with_etf_prices do
      post portfolio_plans_path, params: { plan: { name: "CSI 300", fund_code: "110020", proxy: "510310", amount: "1000",
                                                   day: (Date.current - 40).day.clamp(1, 28), start_on: (Date.current - 40).iso8601, months: "12" } }
      follow_redirect!
    end

    assert_select ".portfolio-flash.is-notice", text: "Plan added."
    assert_select "#plans-table tbody tr[id^=plan-]", 1
    assert_select "#plans-table tbody tr[id^=plan-] td:nth-child(3)", text: /¥[1-2],000/
    assert_select "#plans-table .plan-detail", text: /Valued at the close of/
    # the fixture holds 40 days of prices: too short for any hindsight year
    assert_select ".plan-hindsight li", text: /had not listed yet/, count: 3
  end

  test "a plan whose dividends could not be fetched is still added, with a note" do
    with_etf_prices(fetcher: FakeFetcher.new(failures: { "sh510310" => "timeout" })) do
      post portfolio_plans_path, params: { plan: { name: "CSI 300", fund_code: "", proxy: "510310", amount: "1000",
                                                   day: "10", start_on: Date.current.iso8601, months: "12" } }
      follow_redirect!
    end

    assert_select ".portfolio-flash.is-notice", text: /could not be fetched/
    assert_equal 1, Portfolio.load(@path).plans.size
  end

  test "a fund code in the ETF field is refused with a reason" do
    with_etf_prices do
      post portfolio_plans_path, params: { plan: { name: "CSI 300", fund_code: "", proxy: "110020", amount: "1000",
                                                   day: "10", start_on: Date.current.iso8601, months: "12" } }
      follow_redirect!
    end

    assert_select ".portfolio-flash.is-alert", text: /six-digit code of the ETF/
    assert_empty Portfolio.load(@path).plans
  end

  test "plans can be removed and the deposit rate changed" do
    p = Portfolio.new(@path)
    p.add_plan(name: "x", fund_code: "", proxy: "510310", amount: "1", day: "10", start_on: "2026-01-10", months: "1")

    with_etf_prices do
      patch portfolio_compare_rate_path, params: { compare_rate: "2.0" }
      assert_equal BigDecimal("2.0"), Portfolio.load(@path).compare_rate

      delete portfolio_plan_path(p.plans.first.id)
      assert_empty Portfolio.load(@path).plans
    end
  end

  test "the page reads in Chinese when asked" do
    with_portfolio_file do
      get locale_path("zh"), headers: { "HTTP_REFERER" => "http://www.example.com/portfolio" }
      get portfolio_path
    end

    assert_select "h1", text: "我的配置"
  end

  test "production refuses the page even if a route reaches it" do
    # Routes load lazily on the first request; resolve the path first, or a
    # first request made under the stub would load them without /portfolio.
    path = portfolio_path
    Rails.env.stub(:production?, true) do
      with_portfolio_file { get path }
    end

    assert_response :not_found
  end
end
