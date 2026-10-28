require "test_helper"

class StockPriceAdjustmentImpactReportTest < ActiveSupport::TestCase
  setup do
    dates = 20.times.map { |index| Date.new(2026, 1, 1) + index }
    dates.each do |date|
      StockSignalSnapshot.create!(
        stock: "sz000001", area: Stock::SZSTK, signal_date: date, price: 100.0,
        year_signal: "BUY5", lohas_signal: "BUY5"
      )
    end
    StockCorporateAction.create!(
      area: Stock::SZSTK, stock: "sz000001", ex_date: dates[5],
      category: Stock::TdxQuote::CATEGORY_EX_RIGHTS, cash: 0.0, bonus: 10.0,
      rights: 0.0, rights_price: 0.0, resize: 0.0, factor: 2.0, fetched_at: Time.current
    )
  end

  # The two files are two readings of one measurement. If the numbers could
  # differ between them, a reader who checked the Chinese one would be
  # checking a different claim than a reader who checked the English one.
  test "reports the same numbers in every language" do
    english = Stock::PriceAdjustmentImpactReport.new(lang: "en").call.join("\n")
    chinese = Stock::PriceAdjustmentImpactReport.new(lang: "zh").call.join("\n")

    english_numbers = english.scan(/-?\d+\.\d+%/)
    chinese_numbers = chinese.scan(/-?\d+\.\d+%/)

    assert_not_empty english_numbers
    assert_equal english_numbers, chinese_numbers
  end

  test "writes the Chinese report in Chinese" do
    chinese = Stock::PriceAdjustmentImpactReport.new(lang: "zh").call.join("\n")

    assert_includes chinese, "持有期"
    assert_includes chinese, "模型池"
    assert_includes chinese, "窗口内的除权事件"
    refute_includes chinese, "holding period"
    refute_includes chinese, "Model pool"
  end

  test "refuses a language it has no translation for" do
    error = assert_raises(ArgumentError) { Stock::PriceAdjustmentImpactReport.new(lang: "fr") }
    assert_match(/fr/, error.message)
  end

  # The report tells the reader how to regenerate it. That command has to name
  # the file the reader is looking at and the language it is written in -- and
  # it has to be one command, not the command wrapped in itself.
  test "names its own file and language in the regenerate command" do
    report = Stock::PriceAdjustmentImpactReport.new(
      lang: "zh", output: "docs/price_adjustment_impact.zh.md"
    ).call.join("\n")

    assert_includes report, '`bundle exec rails "price_adjustment_impact[docs/price_adjustment_impact.zh.md,zh]"`'
    refute_includes report, "price_adjustment_impact[bundle"
  end

  test "names the English file in the regenerate command" do
    report = Stock::PriceAdjustmentImpactReport.new(
      lang: "en", output: "docs/price_adjustment_impact.md"
    ).call.join("\n")

    assert_includes report, '`bundle exec rails "price_adjustment_impact[docs/price_adjustment_impact.md]"`'
    refute_includes report, "price_adjustment_impact[bundle"
  end

  test "reports the ex-rights event that moved the price the most" do
    report = Stock::PriceAdjustmentImpactReport.new(lang: "en").call.join("\n")

    assert_includes report, "Ex-rights events inside the window (1)"
    assert_includes report, "sz000001"
  end
end
