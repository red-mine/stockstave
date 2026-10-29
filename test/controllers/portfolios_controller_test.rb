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
