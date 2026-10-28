require "test_helper"

class StockTrendTest < ActiveSupport::TestCase
  # Each band edge differs from its neighbour by a single character in
  # Stock::Trend.classify (> versus >=), so the slope just inside a band is
  # pinned alongside the slope exactly on its boundary. Sampling only the
  # middle of each band would leave every edge untested.
  test "places each slope in its band" do
    {
      0.05 => "strong_uptrend",
      0.049 => "uptrend",
      0.02 => "uptrend",
      0.019 => "weak_uptrend",
      0.011 => "weak_uptrend",
      0.01 => "flat",
      -0.01 => "flat",
      -0.011 => "downtrend",
      -0.05 => "downtrend"
    }.each do |coef, expected|
      assert_equal expected, Stock::Trend.classify(coef), "slope #{coef}"
    end
  end

  test "a slope past the top of the scale stays strong" do
    assert_equal "strong_uptrend", Stock::Trend.classify(1.0)
    assert_equal "strong_uptrend", Stock::Trend.classify(0.051)
  end

  test "an unrecorded slope is not classified" do
    assert_equal "unknown", Stock::Trend.classify(nil)
  end

  test "reads a slope held as a string" do
    assert_equal "uptrend", Stock::Trend.classify("0.03")
  end

  # The band names are words for a reader, so they live in the locale file
  # and the calculation hands back the key. A test that only checked the key
  # would pass with a key that nothing can translate, so both are checked.
  test "labels each band" do
    assert_equal :"trend.strong_uptrend", Stock::Trend.label("strong_uptrend")
    assert_equal :"trend.uptrend", Stock::Trend.label("uptrend")
    assert_equal :"trend.weak_uptrend", Stock::Trend.label("weak_uptrend")
    assert_equal :"trend.flat", Stock::Trend.label("flat")
    assert_equal :"trend.downtrend", Stock::Trend.label("downtrend")
    assert_equal :"trend.unknown", Stock::Trend.label("unknown")

    assert_equal "Strong uptrend", I18n.t(Stock::Trend.label("strong_uptrend"))
    assert_equal "强势上升", I18n.t(Stock::Trend.label("strong_uptrend"), locale: :zh)
  end

  test "falls back to the unknown band for a status it does not know" do
    assert_equal :"trend.unknown", Stock::Trend.label("some_new_band")
  end
end
