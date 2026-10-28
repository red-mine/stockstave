require "test_helper"

class StocksHelperTest < ActionView::TestCase
  test "adds a plain action to each coded signal badge" do
    badge = signal_badge("SAF1")

    assert_dom_equal '<span class="signal-badge signal-positive" title="Safe buy zone"><span class="signal-code">SAF1</span><span class="signal-action">Buy</span></span>', badge
    assert_includes signal_badge("SEL7"), '<span class="signal-action">Sell</span>'
    assert_includes signal_badge("SOX2"), '<span class="signal-action">Hold</span>'
    assert_includes signal_badge("WAT8"), '<span class="signal-action">Wait</span>'
    assert_includes signal_badge("WAT9"), '<span class="signal-action">Avoid</span>'
  end

  test "tones each badge so it cannot disagree with the guide card around it" do
    expected = {
      "SAF1" => "positive", "SOX2" => "strong", "SEL3" => "negative",
      "BUY4" => "positive", "BUY5" => "positive", "SEL6" => "negative",
      "SEL7" => "negative", "WAT8" => "neutral", "WAT9" => "negative",
      "CHP0" => "positive"
    }

    expected.each do |code, tone|
      assert_includes signal_badge(code), "signal-badge signal-#{tone}", "badge #{code}"
    end
  end

  test "tones an unrecognized code as neutral instead of guessing from its prefix" do
    assert_includes signal_badge("BUY9"), "signal-badge signal-neutral"
  end

  test "renders every known badge from the shared signal catalog" do
    Stock::SignalCatalog::ENTRIES.each do |signal|
      badge = signal_badge(signal.fetch(:code))

      # The catalogue hands back the key of the wording; the badge shows the
      # wording, in the language the page is being read in.
      assert_includes badge, %(title="#{I18n.t(signal.fetch(:detail))}")
      assert_includes badge, "signal-#{signal.fetch(:tone)}"
      assert_includes badge, I18n.t(signal.fetch(:badge_action))
    end
  end

  test "labels recent and stale model dates without implying live prices" do
    travel_to Time.zone.local(2026, 8, 2, 12) do
      assert_equal({ label: "Recent", tone: "recent" }, data_recency(Date.new(2026, 7, 31)))
      assert_equal({ label: "Needs update", tone: "stale" }, data_recency(Date.new(2026, 7, 29)))
      assert_equal({ label: "Unavailable", tone: "unknown" }, data_recency(nil))
    end
  end

  test "shows refresh dates in the Shanghai calendar day and tolerates invalid input" do
    assert_equal Date.new(2026, 8, 2), refresh_finished_date("2026-08-01T17:30:00Z")
    assert_nil refresh_finished_date("not-a-time")
    assert_nil refresh_finished_date(nil)
  end

  test "formats completed refresh duration and tolerates incomplete status" do
    assert_equal "5m 28s", refresh_duration(
      started_at: "2026-08-02T08:47:20Z",
      finished_at: "2026-08-02T08:52:48Z"
    )
    assert_equal "9s", refresh_duration(
      started_at: "2026-08-02T08:47:20Z",
      finished_at: "2026-08-02T08:47:29Z"
    )
    assert_nil refresh_duration(started_at: nil, finished_at: nil)
  end

  # The helper classifies slopes for the market page's buy candidates while the
  # engine classifies them for a stock's own trend health. Both must agree, so
  # these pin the helper to the shared rule: a local copy drifting back into
  # StocksHelper shows up here rather than as two pages disagreeing.
  test "classify_trend agrees with the shared rule across every band" do
    [nil, 1.0, 0.05, 0.049, 0.02, 0.019, 0.011, 0.01, -0.01, -0.011, -0.05].each do |slope|
      assert_equal Stock::Trend.classify(slope), classify_trend(slope), "slope #{slope.inspect}"
    end
  end

  test "trend_status_label agrees with the shared labels" do
    Stock::Trend::LABELS.each_key do |status|
      assert_equal I18n.t(Stock::Trend.label(status)), trend_status_label(status), "status #{status}"
    end
  end

  # The band names are read in whichever language the page is in, so the
  # helper has to translate the key the shared rule hands back.
  test "trend_status_label reads the band in the page's language" do
    assert_equal "Strong uptrend", trend_status_label("strong_uptrend")
    assert_equal "强势上升", I18n.t(Stock::Trend.label("strong_uptrend"), locale: :zh)
  end

  test "reports the actual first and last chart dates" do
    series = [
      { name: "Price", data: [[Date.new(2026, 7, 29), 10], [Date.new(2026, 7, 31), 11]] },
      { name: "Trend", data: [["2026-07-30", 10.5]] }
    ]

    assert_equal "2026-07-29 – 2026-07-31", chart_date_range(series)
    assert_equal "Date range unavailable", chart_date_range([])
  end

  test "fundamentals badge reflects the quality verdict" do
    record = StockFundamental.new(
      area: Stock::SZSTK, stock: "sz000001", roe: 5.22, report_date: Date.new(2026, 6, 30),
      revenue_yoy: 1.78, fetched_at: Time.current
    )

    assert_includes fundamentals_badge(record), "fundamentals-pass"
    assert_includes fundamentals_badge(record), "Sound fundamentals"
    assert_includes fundamentals_badge(nil), "fundamentals-unknown"
  end

  test "formats signed percentages and market caps" do
    assert_equal "—", signed_percentage(nil)
    assert_includes signed_percentage(-3.26), "-3.3%"
    assert_includes signed_percentage(12.04), "+12.0%"
    assert_equal "—", market_cap_label(nil)
    assert_equal "225B", market_cap_label(224_526_473_551)
  end
end
