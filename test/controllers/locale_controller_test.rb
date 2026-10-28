require "test_helper"

class LocaleControllerTest < ActionDispatch::IntegrationTest
  class FakeStave
    def known_stock?(_stock)
      true
    end

    def search(_stock)
      [[], nil]
    end

    def strongest_buy_candidates(limit: 6)
      []
    end

    def chart_data(_stock)
      [[], [], [], []]
    end

    def data_dates(_stock)
      [Date.new(2026, 7, 31), Date.new(2026, 7, 31)]
    end

    def trend_health(_stock)
      nil
    end
  end

  setup do
    @referer = { "HTTP_REFERER" => "http://www.example.com/sz" }
  end

  test "the market page reads in English until the reader asks for another language" do
    with_market_page { get stocks_by_area_path("sz") }

    assert_response :success
    assert_select ".buy-heading h2", text: "Buy candidates"
    assert_select "#stock-search-help", text: /full code or a partial symbol/
  end

  test "switching to Chinese renders the same page in Chinese" do
    with_market_page do
      get locale_path("zh"), headers: @referer
      follow_redirect!
    end

    assert_response :success
    assert_select ".buy-heading h2", text: "买入候选"
    assert_select "#stock-search-help", text: /输入完整代码或部分代码/
  end

  # A reader who switched once should not have to switch on every page.
  test "the chosen language is remembered on the next page" do
    with_market_page do
      get locale_path("zh"), headers: @referer
      follow_redirect!
      get stocks_by_area_path("sh")
    end

    assert_response :success
    assert_select ".buy-heading h2", text: "买入候选"
  end

  test "a reader who never switched keeps the language the app is written in" do
    with_market_page { get stocks_by_area_path("sh") }

    assert_response :success
    assert_select ".buy-heading h2", text: "Buy candidates"
  end

  # The route only answers for a language the app actually has, so a stray
  # one never reaches the page.
  test "an unknown language is refused and changes nothing" do
    with_market_page do
      assert_raises(ActionController::RoutingError) { get "/locale/fr" }
      get stocks_by_area_path("sz")
    end

    assert_response :success
    assert_select ".buy-heading h2", text: "Buy candidates"
  end

  test "the switch link offers the other language" do
    with_market_page { get stocks_by_area_path("sz") }

    assert_select "a.locale-switch[href='#{locale_path("zh")}']", text: /切换到中文/
  end

  test "the Chinese page offers the way back" do
    with_market_page do
      get locale_path("zh"), headers: @referer
      follow_redirect!
    end

    assert_select "a.locale-switch[href='#{locale_path("en")}']", text: /Switch to English/
  end

  # A missing translation shows a banner to the reader who asked for Chinese
  # and to nobody else, so the Chinese rendering is checked for it directly.
  test "the Chinese page shows no missing translation" do
    with_market_page do
      get locale_path("zh"), headers: @referer
      follow_redirect!
    end

    assert_response :success
    refute_includes response.body, "translation missing"
  end

  private

  def with_market_page
    status = {
      state: "succeeded", source: "scheduled",
      started_at: "2026-08-01T17:29:51Z", finished_at: "2026-08-01T17:30:00Z"
    }

    Stock::Stave.stub(:new, ->(_area, _days) { FakeStave.new }) do
      Stock::RefreshRun.stub(:new, -> { Struct.new(:status, :scheduled_status).new(status, status) }) do
        yield
      end
    end
  end
end
