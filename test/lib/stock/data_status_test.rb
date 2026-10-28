require "test_helper"

class DataStatusTest < ActiveSupport::TestCase
  test "accepts current coefficients and complete monthly chart coverage" do
    checker = Stock::DataStatus.allocate
    source_date = Date.new(2026, 7, 31)
    market = market_status(source_date: source_date, chart_stocks: 24)

    assert checker.healthy_market?(market)
  end

  test "rejects stale coefficients" do
    checker = Stock::DataStatus.allocate
    market = market_status(source_date: Date.new(2026, 7, 31), chart_stocks: 24)
    market[:tables]["stocks_coefs_years"][:date] = Date.new(2026, 7, 30)

    refute checker.healthy_market?(market)
  end

  test "rejects incomplete chart coverage" do
    checker = Stock::DataStatus.allocate
    market = market_status(source_date: Date.new(2026, 7, 31), chart_stocks: 23)

    refute checker.healthy_market?(market)
  end

  test "rejects substituted chart stocks even when distinct counts match" do
    checker = Stock::DataStatus.allocate
    market = market_status(source_date: Date.new(2026, 7, 31), chart_stocks: 24)
    market[:tables]["stocks_stave_lohas"].merge!(missing_stocks: 1, extra_stocks: 1)

    refute checker.healthy_market?(market)
  end

  test "compares chart and combined stock sets in SQL" do
    StocksCoefsStav.create!(area: Stock::SZSTK, stock: "sz000001")
    StocksStaveLoha.create!(area: Stock::SZSTK, stock: "sz000002")
    checker = Stock::DataStatus.new

    status = checker.send(:stock_set_status, "stocks_stave_lohas", Stock::SZSTK)

    assert_equal({ missing_stocks: 1, extra_stocks: 1 }, status)
  end

  test "refresh areas contains only incomplete markets" do
    checker = Stock::DataStatus.allocate
    report = {
      Stock::SZSTK => { healthy: true },
      Stock::SHSTK => { healthy: false },
      Stock::BJSTK => { healthy: false }
    }

    assert_equal [Stock::SHSTK, Stock::BJSTK], checker.refresh_areas(report)
  end

  test "reports progress around each market inspection" do
    events = []
    checker = Stock::DataStatus.new(progress: ->(area, state) { events << [area, state] })
    checker.stub(:latest_source_date, nil) do
      checker.stub(:table_status, { rows: 0, stocks: 0, date: nil }) do
        checker.call([Stock::SZSTK, Stock::BJSTK])
      end
    end

    assert_equal [
      [Stock::SZSTK, :started], [Stock::SZSTK, :finished],
      [Stock::BJSTK, :started], [Stock::BJSTK, :finished]
    ], events
  end

  private

  def market_status(source_date:, chart_stocks:)
    tables = Stock::DataStatus::TABLES.to_h do |table|
      coefficient = Stock::DataStatus::COEFFICIENT_TABLES.include?(table)
      [
        table,
        {
          rows: 100,
          stocks: coefficient ? 24 : chart_stocks,
          date: coefficient ? source_date : source_date.beginning_of_month,
          missing_stocks: 0,
          extra_stocks: 0
        }
      ]
    end
    { source_date: source_date, tables: tables }
  end
end
