require "test_helper"

class Stock::CorporateActionImporterTest < ActiveSupport::TestCase
  # A stock that does not belong to the market would be read from the wrong
  # .day directory, where the file is not, so its factors would come out as
  # 1.0 and be stored under the wrong market.
  test "refuses a stock that does not belong to the market" do
    importer = Stock::CorporateActionImporter.new(area: Stock::SZSTK)

    report = importer.call(%w[sh600000])

    assert_equal 1, report.failures.size
    assert_match(/does not belong to the sz market/, report.failures.fetch("sh600000"))
    assert_empty StockCorporateAction.where(stock: "sh600000")
  end

  test "a stock of the market is fetched and stored" do
    records = [
      { date: Date.new(2026, 1, 6), category: Stock::TdxQuote::CATEGORY_EX_RIGHTS,
        cash: 1.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 0.0 }
    ]
    result = Stock::CorporateActionFetcher::Result.new(events: { "sz000001" => records }, failures: {})
    fetcher = Object.new
    fetcher.define_singleton_method(:call) { |_stocks, **_options| result }

    report = Stock::CorporateActionImporter.new(area: Stock::SZSTK, fetcher: fetcher).call(%w[sz000001])

    assert_equal 1, report.events
    assert_empty report.failures
    assert_equal 1, StockCorporateAction.where(stock: "sz000001").count
  end
end
