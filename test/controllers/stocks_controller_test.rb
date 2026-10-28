require "test_helper"

class StocksControllerTest < ActionDispatch::IntegrationTest
  class FakeStave
    attr_reader :lookups

    def initialize(known: true, stock_date: Date.new(2026, 7, 31), market_date: Date.new(2026, 7, 31))
      @known = known
      @stock_date = stock_date
      @market_date = market_date
      @lookups = []
    end

    def known_stock?(stock)
      @lookups << stock
      @known
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
      [@stock_date, @market_date]
    end

    def trend_health(_stock)
      nil
    end
  end

  test "preview health returns structured market readiness" do
    report = {
      ready: true, date: Date.new(2026, 7, 31), dates_aligned: true,
      markets: Stock::AREAS.to_h do |area|
        [area, { ready: true, date: Date.new(2026, 7, 31), rows: 2, snapshot_date: Date.new(2026, 7, 31), snapshot_rows: 2 }]
      end
    }

    Stock::PreviewHealth.stub(:new, -> { Struct.new(:call).new(report) }) do
      get preview_health_path
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "ready", body["status"]
    assert_equal Rails.env, body["environment"]
    assert_equal Logger::SEV_LABEL[Rails.logger.level].downcase, body["log_level"]
    assert_equal "2026-07-31", body["date"]
    assert_equal true, body["dates_aligned"]
    assert_equal 2, body.dig("markets", "sz", "rows")
  end

  test "preview health fails when any market is incomplete" do
    report = { ready: false, markets: { bj: { ready: false, date: nil, rows: 0 } } }

    Stock::PreviewHealth.stub(:new, -> { Struct.new(:call).new(report) }) do
      get preview_health_path
    end

    assert_response :service_unavailable
    assert_equal "incomplete", response.parsed_body["status"]
  end

  test "market page uses the market from the route" do
    areas = []

    Stock::Stave.stub(:new, ->(area, _days) { areas << area; FakeStave.new }) do
      get stocks_by_area_path("sh")
    end

    assert_response :success
    assert_equal [Stock::SHSTK], areas
    assert_select ".app-shell"
    assert_select "a[href='#{stocks_by_area_path(Stock::BJSTK)}']", text: "BJ"
    assert_select "#stock-search-help", text: /full code or a partial symbol/
    assert_select "input#stock[inputmode='search'][enterkeyhint='search'][autocapitalize='none'][aria-describedby='stock-search-help']"
    assert_select ".buy-heading > div:first-child > a.mobile-signal-jump[href='#current-signals']", text: /Jump to buy\/sell signals/
    assert_select "section#current-signals.signal-panel"
  end

  test "market page displays the last successful daily refresh" do
    status = {
      state: "succeeded",
      source: "scheduled",
      started_at: "2026-08-01T17:29:51Z",
      finished_at: "2026-08-01T17:30:00Z"
    }

    Stock::RefreshRun.stub(:new, -> { Struct.new(:status, :scheduled_status).new(status, status) }) do
      get stocks_by_area_path("sz")
    end

    assert_response :success
    assert_select ".refresh-status", text: /Scheduled refresh verified 2026-08-02 in 9s/
  end

  test "market page discloses automatic stale-lock recovery" do
    status = {
      state: "succeeded", source: "scheduled", recovered_stale_lock: true,
      started_at: "2026-08-01T17:29:51Z", finished_at: "2026-08-01T17:30:00Z"
    }

    Stock::RefreshRun.stub(:new, -> { Struct.new(:status, :scheduled_status).new(status, status) }) do
      get stocks_by_area_path("sz")
    end

    assert_response :success
    assert_select ".refresh-status", text: /after recovering an expired lock/
  end

  test "market page displays an installed automatic refresh schedule" do
    schedule = { enabled: true, time: "20:30" }

    Stock::RefreshSchedule.stub(:new, -> { Struct.new(:status).new(schedule) }) do
      get stocks_by_area_path("sz")
    end

    assert_response :success
    assert_select ".refresh-schedule", text: /Automatic refresh daily at 20:30/
  end

  test "market page preserves scheduled verification after a manual refresh" do
    latest = {
      state: "succeeded", source: "manual",
      started_at: "2026-08-02T16:46:50Z", finished_at: "2026-08-02T16:47:05Z"
    }
    scheduled = {
      state: "succeeded", source: "scheduled",
      started_at: "2026-08-01T17:29:51Z", finished_at: "2026-08-01T17:30:00Z"
    }
    runner = Struct.new(:status, :scheduled_status).new(latest, scheduled)

    Stock::RefreshRun.stub(:new, runner) do
      get stocks_by_area_path("sz")
    end

    assert_response :success
    assert_select ".refresh-status", text: /Refresh verified 2026-08-03 in 15s/
    assert_select ".scheduled-refresh-status", text: /Scheduled refresh verified 2026-08-02 in 9s/
  end

  test "market page preserves a scheduled failure after a manual refresh" do
    latest = {
      state: "succeeded", source: "manual",
      started_at: "2026-08-02T16:46:50Z", finished_at: "2026-08-02T16:47:05Z"
    }
    scheduled = {
      state: "failed", source: "scheduled",
      started_at: "2026-08-02T12:30:00Z", finished_at: "2026-08-02T12:31:00Z",
      error: "source unavailable"
    }
    runner = Struct.new(:status, :scheduled_status).new(latest, scheduled)

    Stock::RefreshRun.stub(:new, runner) do
      get stocks_by_area_path("sz")
    end

    assert_response :success
    assert_select ".refresh-status:not(.scheduled-refresh-status)", text: /Refresh verified 2026-08-03 in 15s/
    assert_select ".scheduled-refresh-status.is-failed", text: /Last scheduled refresh failed 2026-08-02/
  end

  test "market page preserves a running scheduled refresh after a manual refresh" do
    latest = { state: "succeeded", source: "manual" }
    scheduled = { state: "running", source: "scheduled", started_at: "2026-08-02T12:30:00Z" }
    runner = Struct.new(:status, :scheduled_status).new(latest, scheduled)

    Stock::RefreshRun.stub(:new, runner) do
      get stocks_by_area_path("sz")
    end

    assert_response :success
    assert_select ".scheduled-refresh-status.is-running", text: /Scheduled refresh is running/
  end

  test "stock analysis preserves its market query parameter" do
    areas = []

    Stock::Stave.stub(:new, ->(area, _days) { areas << area; FakeStave.new }) do
      get stock_analysis_path("600000", area: "sh")
    end

    assert_response :success
    assert_equal [Stock::SHSTK], areas
    assert_select ".chart-card", count: 4
  end

  test "stock analysis labels charts with their actual date range" do
    stave = FakeStave.new
    long_series = [{ name: "Price", data: [[Date.new(2023, 1, 3), 10], [Date.new(2026, 7, 31), 12]] }]
    year_series = [{ name: "Price", data: [[Date.new(2025, 8, 1), 11], [Date.new(2026, 7, 31), 12]] }]
    stave.define_singleton_method(:chart_data) { |_stock| [long_series, year_series, long_series, year_series] }

    Stock::Stave.stub(:new, ->(*) { stave }) do
      get stock_analysis_path("000522", area: Stock::SZSTK)
    end

    assert_response :success
    assert_select ".chart-sampling-note", text: /one point per month.*one point per quarter.*authoritative final trading date/m
    # The note carries markup, so its key ends in _html and Rails has to
    # render that markup rather than show it to the reader.
    assert_select ".chart-sampling-note strong", text: /Why can the last plotted date be earlier/
    assert_select ".chart-period", count: 2, text: /3\.5 years.*2023-01-03.*2026-07-31/m
    assert_select ".chart-period", count: 2, text: /quarterly/
    assert_select ".chart-period", count: 2, text: /1 year.*2025-08-01.*2026-07-31/m
    assert_select ".chart-period", count: 2, text: /monthly/
  end

  test "stock analysis accepts a market-prefixed identifier" do
    calls = []
    stave = FakeStave.new

    Stock::Stave.stub(:new, ->(area, _days) { calls << area; stave }) do
      get stock_analysis_path("SH600000", area: Stock::SZSTK)
    end

    assert_response :success
    assert_equal [Stock::SHSTK], calls
    assert_equal ["sh600000"], stave.lookups
    assert_select "h1", text: "SH600000"
    assert_select "a[href='#{stocks_by_area_path(Stock::SHSTK, anchor: "current-signals")}']", text: /Back to SH signals/
  end

  test "stock analysis adds the selected market to an unprefixed identifier" do
    stave = FakeStave.new

    Stock::Stave.stub(:new, ->(*) { stave }) do
      get stock_analysis_path("600000", area: Stock::SHSTK)
    end

    assert_response :success
    assert_equal ["sh600000"], stave.lookups
    assert_select "h1", text: "SH600000"
  end

  test "stock analysis identifies historical data using the stock's own date" do
    stave = FakeStave.new(
      stock_date: Date.new(2013, 3, 13),
      market_date: Date.new(2026, 7, 31)
    )

    Stock::Stave.stub(:new, ->(*) { stave }) do
      get stock_analysis_path("000522", area: Stock::SZSTK)
    end

    assert_response :success
    assert_select ".data-freshness.is-historical", text: /2013-03-13/
    assert_select ".data-freshness", text: /SZ market data continues through 2026-07-31/
  end

  test "stock analysis returns Buy candidates to their originating section" do
    Stock::Stave.stub(:new, ->(*) { FakeStave.new }) do
      get stock_analysis_path("002653", area: Stock::SZSTK, return_to: "buy-candidates")
    end

    assert_response :success
    assert_select "a.back-link[href='#{stocks_by_area_path(Stock::SZSTK, anchor: "buy-candidates")}']", text: /Back to SZ signals/
  end

  test "stock analysis rejects an unrecognized return section" do
    Stock::Stave.stub(:new, ->(*) { FakeStave.new }) do
      get stock_analysis_path("002653", area: Stock::SZSTK, return_to: "outside")
    end

    assert_response :success
    assert_select "a.back-link[href='#{stocks_by_area_path(Stock::SZSTK, anchor: "current-signals")}']"
  end

  test "stock analysis shows recorded signal history without reconstructing missing history" do
    StockSignalSnapshot.create!(
      stock: "sz000522", area: Stock::SZSTK, signal_date: Date.new(2026, 7, 30),
      price: 10.5, year_signal: "SAF1", lohas_signal: "BUY5"
    )
    StockSignalSnapshot.create!(
      stock: "sz000522", area: Stock::SZSTK, signal_date: Date.new(2026, 7, 31),
      price: 10.8, year_signal: "BUY5", lohas_signal: "BUY5"
    )

    Stock::Stave.stub(:new, ->(*) { FakeStave.new }) do
      get stock_analysis_path("000522", area: Stock::SZSTK)
    end

    assert_response :success
    assert_select ".signal-timeline", count: 1
    assert_select ".current-decision.decision-buy", count: 1, text: /Buy agreement.*2026-07-31.*10.8/m
    assert_select ".decision-signals", text: /Year.*BUY5.*LOHAS.*BUY5/m
    direct_guide_path = signal_guide_path(area: Stock::SZSTK, anchor: "signal-buy5")
    assert_select ".decision-signals a.signal-guide-link[href='#{direct_guide_path}']", count: 2
    assert_select ".decision-reason", text: /Both recorded horizons.*not personalized financial advice/
    assert_select "a.decision-guide[href='#{signal_guide_path(area: Stock::SZSTK)}']", text: /Understand these signals/
    assert_select ".timeline-entry", count: 2
    assert_select ".timeline-entry.is-change", count: 1, text: /2026-07-31.*BUY5.*10.8/m
    assert_select ".timeline-signals a.signal-guide-link[href='#{direct_guide_path}']", count: 3
    assert_select ".timeline-signals a.signal-guide-link[href='#{signal_guide_path(area: Stock::SZSTK, anchor: "signal-saf1")}']", count: 1
    assert_select "a[href='#{signal_history_path(area: Stock::SZSTK)}']", text: /All market history/
  end

  test "stock analysis defaults invalid market input to Shenzhen" do
    areas = []

    Stock::Stave.stub(:new, ->(area, _days) { areas << area; FakeStave.new }) do
      get stock_analysis_path("000001", area: "../../outside")
    end

    assert_response :success
    assert_equal [Stock::SZSTK], areas
  end

  test "rejects malformed stock identifiers" do
    Stock::Stave.stub(:new, ->(*) { flunk "engine should not be initialized" }) do
      get stock_analysis_path("bad!", area: Stock::BJSTK)
    end

    assert_response :not_found
    assert_select "h1", text: "Stock not found"
    assert_select "a[href='#{stocks_by_area_path(Stock::BJSTK)}']", text: "Return to market signals"
  end

  test "rejects alphabetic stock identifiers" do
    Stock::Stave.stub(:new, ->(*) { flunk "engine should not be initialized" }) do
      get stock_analysis_path("shabcdef")
    end

    assert_response :not_found
  end

  test "returns not found when a stock is absent from the selected market" do
    Stock::Stave.stub(:new, ->(*) { FakeStave.new(known: false) }) do
      get stock_analysis_path("600000", area: Stock::SHSTK)
    end

    assert_response :not_found
  end

  test "rejects malformed stock searches" do
    Stock::Stave.stub(:new, ->(*) { flunk "engine should not be initialized" }) do
      get stocks_by_area_path(Stock::SHSTK), params: { stock: "%" }
    end

    assert_response :bad_request
    assert_select "h1", text: "Invalid search"
    assert_select "a[href='#{stocks_by_area_path(Stock::SHSTK)}']", text: "Return to market signals"
  end

  test "full prefixed search switches to the encoded market" do
    StocksCoefsStav.create!(
      stock: "sh600000", area: Stock::SHSTK, price: 12.34,
      year_signal: "SAF1", lohas_signal: "BUY5", date: Date.new(2026, 7, 31)
    )

    get stocks_by_area_path(Stock::SZSTK), params: { stock: "SH600000" }

    assert_redirected_to stocks_by_area_path(Stock::SHSTK, stock: "sh600000", anchor: "current-signals")
    follow_redirect!
    assert_response :success
    assert_select ".market-tab.is-active", text: "SH"
    assert_select ".search-summary", text: /1 result.*SH600000/
    assert_select ".stock-code", text: /SH600000/
  end

  test "market signals are available as JSON" do
    signal = StocksCoefsStav.create!(
      stock: "sh600000",
      area: Stock::SHSTK,
      loha: 1.2,
      year: 0.8,
      price: 12.34,
      lohas_signal: "BUY5",
      date: Date.new(2026, 7, 31)
    )

    get stocks_by_area_path(Stock::SHSTK, format: :json)

    assert_response :success
    payload = response.parsed_body
    assert_equal ["sh600000"], payload.pluck("stock")
    assert_equal signal.price, payload.first.fetch("price")
    assert_equal stock_analysis_url("sh600000", area: Stock::SHSTK, format: :json), payload.first.fetch("url")
  end

  test "market page labels stocks whose data ended before the market date" do
    StocksCoefsStav.create!(
      stock: "sz000522", area: Stock::SZSTK, price: 10,
      lohas_signal: "BUY5", date: Date.new(2013, 3, 13)
    )
    StocksCoefsStav.create!(
      stock: "sz000001", area: Stock::SZSTK, price: 11,
      lohas_signal: "BUY5", date: Date.new(2026, 7, 31)
    )

    get stocks_by_area_path(Stock::SZSTK)

    assert_response :success
    assert_equal ["Stock", "Year signal", "LOHAS signal"], css_select(".stock-table th").first(3).map { |header| header.text.strip }
    assert_select ".stock-table th.metric-column", count: 7
    assert_select ".stock-table tbody tr:first-child td.metric-column", count: 7
    assert_select ".mobile-table-note", text: /Tap a stock for price, trend, channel, and chart details/
    assert_select ".stock-code a[aria-label='Open SZ000001 analysis'] .stock-open-arrow", text: "→"
    guide_path = signal_guide_path(area: Stock::SZSTK)
    assert_select "a.guide-link[href='#{guide_path}']", text: /Open signal guide/
    assert_select "a.signal-guide-link[href='#{guide_path}']", count: 2
    assert_select "a.signal-guide-link[href='#{guide_path}#signal-buy5']", count: 2
    assert_select "tr.is-historical", count: 1 do
      assert_select ".stock-code", text: /SZ000522/
      assert_select ".historical-label", text: "Historical"
      assert_select ".historical-date", text: "Ended 2013-03-13"
    end
    assert_select "tr:not(.is-historical) .stock-code", text: /SZ000001/
  end

  test "market page ranks current buy-family candidates" do
    recent_date = Date.current
    StocksCoefsStav.create!(
      stock: "sz002653", area: Stock::SZSTK, price: 62.38,
      year_signal: "BUY5", lohas_signal: "BUY5", date: recent_date,
      year: 0.04, loha: 0.03
    )
    StocksCoefsStav.create!(
      stock: "sz000001", area: Stock::SZSTK, price: 11,
      year_signal: "SAF1", lohas_signal: "BUY5", date: recent_date,
      year: 0.01, loha: 0.02
    )
    StocksCoefsStav.create!(
      stock: "sz000002", area: Stock::SZSTK, price: 10,
      year_signal: "BUY5", lohas_signal: "BUY5", date: recent_date - 1,
      year: 0.05, loha: 0.04
    )
    StocksCoefsStav.create!(
      stock: "sz880016", area: Stock::SZSTK, price: 89,
      year_signal: "BUY5", lohas_signal: "BUY5", date: recent_date,
      year: 0.03, loha: 0.02
    )

    get stocks_by_area_path(Stock::SZSTK)

    assert_response :success
    assert_select "section#buy-candidates.buy-panel", count: 1
    assert_select ".buy-card", count: 1, text: /SZ002653/
    assert_select ".buy-card", text: /BUY5 \+ BUY5/
    assert_select ".candidate-trend", count: 1, text: /Uptrend/
    assert_select ".candidate-history", text: /First recorded/
    assert_select ".candidate-score", text: %r{/100}
    assert_select ".candidate-score", text: /agreement/
    assert_select ".candidate-details", count: 2, text: /Why this score?/
    assert_select ".candidate-mobile-reasons", count: 2, text: /Why this score.*Both horizons are in a buy-family signal/m
    assert_select "article.buy-card", count: 2
    assert_select ".candidate-details a", count: 0
    assert_select "a.candidate-open[href='#{stock_analysis_path("sz002653", area: Stock::SZSTK, return_to: "buy-candidates")}']", text: /Open analysis/
    assert_select ".data-status-recent", text: "Recent"
    assert_select "a.history-shortcut[href='#{signal_history_path(area: Stock::SZSTK)}']", text: /View signal history/
    assert_select ".risk-note", text: /not a guarantee/
  end

  test "search results hide the market-wide buy shortlist" do
    get stocks_by_area_path(Stock::SZSTK), params: { stock: "002653" }

    assert_response :success
    assert_select ".buy-panel", count: 0
    assert_select "a.clear-search[href='#{stocks_by_area_path(Stock::SZSTK)}']", text: "Clear search"
    assert_select ".search-summary", text: /result.*matching “002653”/
  end

  test "market action filters use conservative signal groups" do
    {
      "sz000001" => ["BUY5", "SAF1"],
      "sz000002" => ["BUY5", "SEL7"],
      "sz000003" => ["WAT9", "BUY5"]
    }.each do |stock, (year_signal, lohas_signal)|
      StocksCoefsStav.create!(
        stock: stock, area: Stock::SZSTK, price: 10,
        year_signal: year_signal, lohas_signal: lohas_signal, date: Date.new(2026, 7, 31)
      )
    end

    get stocks_by_area_path(Stock::SZSTK), params: { signal: "buy" }
    assert_response :success
    assert_select ".stock-code", count: 1, text: /SZ000001/
    assert_select ".signal-filter.is-active", text: /Buy agreement.*1/m
    assert_select ".signal-filter", count: 4
    assert_select ".signal-filter", text: /All.*3/m
    %w[all buy sell watch].each do |filter|
      assert_select "a.signal-filter[href='#{stocks_by_area_path(Stock::SZSTK, signal: filter, anchor: "current-signals")}']", count: 1
    end
    assert_select "a.signal-guide-link[href='#{signal_guide_path(area: Stock::SZSTK, return_signal: "buy", anchor: "signal-buy5")}']", count: 1
    assert_select "a.signal-guide-link[href='#{signal_guide_path(area: Stock::SZSTK, return_signal: "buy", anchor: "signal-saf1")}']", count: 1

    get stocks_by_area_path(Stock::SZSTK), params: { signal: "sell" }
    assert_select ".stock-code", count: 1, text: /SZ000002/

    get stocks_by_area_path(Stock::SZSTK), params: { signal: "watch" }
    assert_select ".stock-code", count: 1, text: /SZ000003/
  end

  # A stock is listed when either horizon produced a signal; checking only the
  # LOHAS one hid stocks whose year reading was a sell alert.
  test "a stock is listed when either horizon produced a signal" do
    StocksCoefsStav.create!(
      stock: "sz000001", area: Stock::SZSTK, price: 10,
      year_signal: "SEL7", lohas_signal: nil, date: Date.new(2026, 7, 31)
    )
    StocksCoefsStav.create!(
      stock: "sz000002", area: Stock::SZSTK, price: 11,
      year_signal: nil, lohas_signal: "BUY5", date: Date.new(2026, 7, 31)
    )
    StocksCoefsStav.create!(
      stock: "sz000003", area: Stock::SZSTK, price: 12,
      year_signal: nil, lohas_signal: nil, date: Date.new(2026, 7, 31)
    )

    get stocks_by_area_path(Stock::SZSTK)
    assert_response :success
    assert_select ".stock-code", count: 2
    assert_select ".stock-code", text: /SZ000001/
    assert_select ".stock-code", text: /SZ000002/
    assert_select ".stock-code", text: /SZ000003/, count: 0
  end

  # A horizon can be unrecorded, and SignalFamily.classify treats that as
  # neither buy nor sell. The SQL filter has to agree, or a stock shows under
  # All and under no filter at all.
  test "a stock with one horizon unrecorded is grouped as SignalFamily would" do
    {
      "sz000001" => [nil, "BUY5"],
      "sz000003" => [nil, "SEL7"],
      "sz000005" => [nil, "WAT9"]
    }.each do |stock, (year_signal, lohas_signal)|
      StocksCoefsStav.create!(
        stock: stock, area: Stock::SZSTK, price: 10,
        year_signal: year_signal, lohas_signal: lohas_signal, date: Date.new(2026, 7, 31)
      )
    end

    get stocks_by_area_path(Stock::SZSTK)
    assert_response :success
    assert_select ".signal-filter", text: /All.*3/m
    assert_select ".signal-filter", text: /Buy agreement.*0/m
    assert_select ".signal-filter", text: /Sell alert.*1/m
    assert_select ".signal-filter", text: /Watch.*2/m

    get stocks_by_area_path(Stock::SZSTK), params: { signal: "watch" }
    assert_select ".stock-code", count: 2
    assert_select ".stock-code", text: /SZ000001/
    assert_select ".stock-code", text: /SZ000005/

    get stocks_by_area_path(Stock::SZSTK), params: { signal: "sell" }
    assert_select ".stock-code", count: 1, text: /SZ000003/

    get stocks_by_area_path(Stock::SZSTK), params: { signal: "buy" }
    assert_select ".stock-code", count: 0
  end

  test "invalid action filters safely default to all" do
    get stocks_by_area_path(Stock::SZSTK), params: { signal: "unknown" }

    assert_response :success
    assert_select ".signal-filter.is-active", text: /All.*0/m
  end

  test "stock analysis is available as JSON" do
    stave = FakeStave.new

    Stock::Stave.stub(:new, ->(*) { stave }) do
      get stock_analysis_path("600000", area: Stock::SHSTK, format: :json)
    end

    assert_response :success
    payload = response.parsed_body
    assert_equal "sh600000", payload.fetch("stock")
    assert_equal Stock::SHSTK, payload.fetch("area")
    assert_equal "2026-07-31", payload.fetch("data_date")
    assert_equal "2026-07-31", payload.fetch("market_date")
    assert_equal false, payload.fetch("historical")
    assert_nil payload.fetch("decision")
    assert_nil payload.fetch("latest_signal")
    assert_equal [], payload.fetch("signal_history")
    assert_equal %w[bolls_lohas bolls_years stave_lohas stave_years], payload.fetch("charts").keys.sort
  end

  test "stock analysis JSON includes the shared decision and recorded timeline" do
    StockSignalSnapshot.create!(
      stock: "sh600000", area: Stock::SHSTK, signal_date: Date.new(2026, 7, 30),
      price: 10.0, year_signal: "WAT9", lohas_signal: "BUY5"
    )
    StockSignalSnapshot.create!(
      stock: "sh600000", area: Stock::SHSTK, signal_date: Date.new(2026, 7, 31),
      price: 10.5, year_signal: "BUY5", lohas_signal: "SAF1"
    )

    Stock::Stave.stub(:new, ->(*) { FakeStave.new }) do
      get stock_analysis_path("600000", area: Stock::SHSTK, format: :json)
    end

    assert_response :success
    payload = response.parsed_body
    assert_equal "buy", payload.fetch("decision")
    assert_equal "2026-07-31", payload.dig("latest_signal", "date")
    assert_equal "BUY5", payload.dig("latest_signal", "year_signal")
    assert_equal 2, payload.fetch("signal_history").size
    assert_equal true, payload.fetch("signal_history").first.fetch("changed")
  end

  test "signal guide explains every active signal on a mobile-friendly page" do
    get signal_guide_path(area: Stock::SHSTK)

    assert_response :success
    assert_select "h1", text: "Signal guide"
    assert_select ".guide-card", count: 10
    assert_select "a[href='/stave/stave.png?v=4']", text: /restored original illustrated guide/
    assert_select ".example-item", count: 10
    assert_select ".example-item", text: /Buy while the channel holds/
    assert_select ".legacy-code", count: 0
    %w[SAF1 SOX2 SEL3 BUY4 BUY5 SEL6 SEL7 WAT8 WAT9 CHP0].each do |code|
      assert_select ".guide-card#signal-#{code.downcase}", text: /#{code}/
    end
    assert_select "a[href='#{stocks_by_area_path(Stock::SHSTK, anchor: "current-signals")}']", text: /Back to SH signals/
  end

  # The guide colours a card from its own tone field while the badge inside it
  # is toned by the helper. WAT9 was negative on the card and neutral on the
  # badge, so this asserts the two agree for every signal rather than trusting
  # either list to be updated alongside the other.
  test "each guide card is toned the same as the badge it carries" do
    get signal_guide_path(area: Stock::SHSTK)

    assert_response :success
    {
      "SAF1" => "positive", "SOX2" => "strong", "SEL3" => "negative",
      "BUY4" => "positive", "BUY5" => "positive", "SEL6" => "negative",
      "SEL7" => "negative", "WAT8" => "neutral", "WAT9" => "negative",
      "CHP0" => "positive"
    }.each do |code, tone|
      assert_select "#signal-#{code.downcase}.guide-card-#{tone}", 1, "card #{code}"
      assert_select "#signal-#{code.downcase} .signal-badge.signal-#{tone}", 1, "badge #{code}"
    end
  end

  test "signal guide returns to the originating signal filter" do
    get signal_guide_path(area: Stock::SZSTK, return_signal: "sell", anchor: "signal-sel7")

    assert_response :success
    assert_select "a.back-link[href='#{stocks_by_area_path(Stock::SZSTK, signal: "sell", anchor: "current-signals")}']"
  end

  test "signal history reports evidence coverage without premature performance claims" do
    2.times do |index|
      StockSignalSnapshot.create!(
        stock: "sz00000#{index}", area: Stock::SZSTK,
        signal_date: Date.new(2026, 7, 31), price: 10 + index
      )
    end

    get signal_history_path(area: Stock::SZSTK)

    assert_response :success
    assert_select "h1", text: "Signal history"
    assert_select ".history-card", count: 3
    assert_select ".history-card", text: /SZ.*Trading dates.*1.*Snapshot rows.*2/m
    assert_select ".history-state.is-collecting", count: 3
    assert_select ".performance-panel", count: 0
    assert_select ".history-note", text: /sample size, average return, win rate, and drawdown/
    assert_select "a[href='#{stocks_by_area_path(Stock::SZSTK)}']", text: /Back to SZ signals/
  end

  # The card's readiness used to be the literal 20 while the report read
  # MINIMUM_DATES, so the two could disagree. These pin the card to the report:
  # one date short of the minimum must still read as collecting, and reaching
  # the minimum must read as ready.
  test "signal history still collects one date short of the report's minimum" do
    (Stock::SignalPerformance::MINIMUM_DATES - 1).times do |index|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK,
        signal_date: Date.new(2026, 1, 1) + index, price: 10.0
      )
    end

    get signal_history_path(area: Stock::SZSTK)

    assert_response :success
    assert_select ".history-state.is-ready", count: 0
    assert_select ".history-state.is-collecting", count: 3
    assert_select ".history-note", text: /at least #{Stock::SignalPerformance::MINIMUM_DATES} trading dates/
  end

  test "signal history marks a market ready at the report's minimum" do
    Stock::SignalPerformance::MINIMUM_DATES.times do |index|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK,
        signal_date: Date.new(2026, 1, 1) + index, price: 10.0
      )
    end

    get signal_history_path(area: Stock::SZSTK)

    assert_response :success
    assert_select ".history-state.is-ready", count: 1
    assert_select ".history-state.is-collecting", count: 2
    # The measurement caliber is known before any result exists, so it shows
    # even while the report is still collecting.
    assert_select ".method-note", text: /model pool of the same day/
  end

  test "signal history displays qualified forward performance with warnings" do
    cohort = Stock::SignalPerformance::Cohort.new(
      year_signal: "BUY5", lohas_signal: "BUY5", sample_size: 75,
      win_rate: 60.0, average_return: 1.2, average_drawdown: -2.1,
      trend_group: nil, baseline_return: 2.5, excess_return: -1.3, excess_dates: 14
    )
    baseline = Stock::SignalPerformance::Baseline.new(average_return: 2.5, dates: 14, sample_size: 300)
    report = Stock::SignalPerformance::Report.new(ready: true, dates: 20, horizon: 5, cohorts: [cohort], baseline: baseline)

    Stock::SignalPerformance.stub(:new, ->(*) { Struct.new(:call).new(report) }) do
      get signal_history_path(area: Stock::SZSTK)
    end

    assert_response :success
    assert_select ".performance-panel", count: 1
    assert_select ".performance-card", text: /BUY5 \+ BUY5.*75.*60.0%.*1.2%.*-2.1%/m
    assert_select ".performance-warning", text: /not a forecast.*transaction costs are not yet deducted/
  end

  # The absolute return says whether the stocks went up; the excess says
  # whether the signal chose them better than the pool it could have picked
  # from. Showing one without the other is how a rising market reads as a
  # working strategy.
  test "signal history shows the excess against the model pool" do
    cohort = Stock::SignalPerformance::Cohort.new(
      year_signal: "BUY5", lohas_signal: "BUY5", sample_size: 70,
      win_rate: 60.0, average_return: 10.41, average_drawdown: -2.1,
      trend_group: nil, baseline_return: 16.11, excess_return: -5.7, excess_dates: 14
    )
    baseline = Stock::SignalPerformance::Baseline.new(average_return: 16.11, dates: 14, sample_size: 300)
    report = Stock::SignalPerformance::Report.new(ready: true, dates: 20, horizon: 5, cohorts: [cohort], baseline: baseline)

    Stock::SignalPerformance.stub(:new, ->(*) { Struct.new(:call).new(report) }) do
      get signal_history_path(area: Stock::SZSTK)
    end

    assert_response :success
    assert_select ".performance-card", text: /Model pool.*16.11%/m
    assert_select ".performance-card", text: /BUY5 \+ BUY5.*Pool return.*16.11%.*Excess vs pool.*-5.7%/m
    assert_select ".method-note", text: /model pool of the same day/
  end

  test "signal history shows the strategy simulation with a benchmark comparison" do
    dates = [Date.new(2026, 1, 1), Date.new(2026, 1, 2), Date.new(2026, 1, 5)]
    equity_curve = [
      Stock::StrategySimulation::EquityPoint.new(date: dates[0], equity: 100_000.0),
      Stock::StrategySimulation::EquityPoint.new(date: dates[1], equity: 101_000.0),
      Stock::StrategySimulation::EquityPoint.new(date: dates[2], equity: 103_000.0)
    ]
    trade = Stock::StrategySimulation::Trade.new(
      stock: "sz000001", entry_date: dates[0], exit_date: dates[2],
      entry_price: 10.0, exit_price: 10.3, return_pct: 3.0, reason: "sell",
      weight: 1.0, zone: -2
    )
    simulation = Stock::StrategySimulation::Result.new(
      ready: true, dates: dates.size, starting_cash: 100_000.0, final_equity: 103_000.0,
      total_return: 3.0, max_drawdown: -1.0, trades: [trade], equity_curve: equity_curve,
      anomalous_trades: 0
    )
    benchmark = Stock::IndexBenchmark::Result.new(
      available: true, index_code: "sz399001", total_return: 2.0,
      prices: { dates[0] => 100.0, dates[1] => 100.5, dates[2] => 102.0 }
    )

    Stock::StrategySimulation.stub(:new, ->(*) { Struct.new(:call).new(simulation) }) do
      Stock::IndexBenchmark.stub(:new, ->(*) { Struct.new(:call).new(benchmark) }) do
        get signal_history_path(area: Stock::SZSTK)
      end
    end

    assert_response :success
    assert_select "#simulation-title", text: "Strategy simulation"
    assert_select ".performance-card", text: /Final equity.*103,?000\.00/m
    assert_select ".performance-card", text: /Index.*sz399001.*Buy . hold return.*2\.0%/m
    assert_select ".performance-card", text: /Strategy vs\. index.*1\.0pp/m
    assert_select "table.stock-table tbody tr", count: 3
  end

  test "signal history shows a plain note when no index benchmark is available" do
    dates = [Date.new(2026, 1, 1)] * 20
    dates = dates.each_with_index.map { |_, index| Date.new(2026, 1, 1) + index }
    equity_curve = dates.map { |date| Stock::StrategySimulation::EquityPoint.new(date: date, equity: 100_000.0) }
    simulation = Stock::StrategySimulation::Result.new(
      ready: true, dates: dates.size, starting_cash: 100_000.0, final_equity: 100_000.0,
      total_return: 0.0, max_drawdown: 0.0, trades: [], equity_curve: equity_curve,
      anomalous_trades: 0
    )
    benchmark = Stock::IndexBenchmark::Result.new(available: false, index_code: nil, total_return: nil, prices: {})

    Stock::StrategySimulation.stub(:new, ->(*) { Struct.new(:call).new(simulation) }) do
      Stock::IndexBenchmark.stub(:new, ->(*) { Struct.new(:call).new(benchmark) }) do
        get signal_history_path(area: Stock::BJSTK)
      end
    end

    assert_response :success
    assert_select ".performance-card", text: /No index data available for BJ/
  end

  test "signal history says which price basis the returns were measured on" do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each do |date|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK, signal_date: date, price: 100.0,
        year_signal: "BUY5", lohas_signal: "BUY5"
      )
    end

    get signal_history_path(area: Stock::SZSTK)

    assert_response :success
    assert_select ".method-note", text: /raw closes/

    StockCorporateAction.create!(
      area: Stock::SZSTK, stock: "sz000001", ex_date: Date.new(2026, 1, 6),
      category: Stock::TdxQuote::CATEGORY_EX_RIGHTS, cash: 0.0, bonus: 10.0,
      rights: 0.0, rights_price: 0.0, resize: 0.0, factor: 2.0, fetched_at: Time.current
    )

    get signal_history_path(area: Stock::SZSTK)

    assert_response :success
    assert_select ".method-note", text: /adjusted closes/
  end

  test "JSON errors use a structured response" do
    Stock::Stave.stub(:new, ->(*) { flunk "engine should not be initialized" }) do
      get stock_analysis_path("bad!", format: :json)

      assert_response :not_found
      assert_equal({ "error" => "Stock not found" }, response.parsed_body)

      get stocks_by_area_path(Stock::SZSTK, format: :json), params: { stock: "%" }
    end

    assert_response :bad_request
    assert_equal({ "error" => "Invalid stock search" }, response.parsed_body)
  end
end
