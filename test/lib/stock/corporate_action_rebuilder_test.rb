require "test_helper"

class Stock::CorporateActionRebuilderTest < ActiveSupport::TestCase
  def store_event(stock: "sz000001", area: Stock::SZSTK, ex_date: Date.new(2026, 1, 6),
                  category: Stock::TdxQuote::CATEGORY_EX_RIGHTS, cash: 0.0, bonus: 10.0,
                  rights: 0.0, rights_price: 0.0, resize: 0.0)
    StockCorporateAction.create!(
      area: area, stock: stock, ex_date: ex_date, category: category,
      cash: cash, bonus: bonus, rights: rights, rights_price: rights_price, resize: resize,
      factor: 1.0, fetched_at: Time.current
    )
  end

  test "stores the factor the event leaves behind" do
    Dir.mktmpdir do |root|
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 5.0],
        [Date.new(2026, 1, 7), 5.0]
      ])
      store_event

      report = with_data_root(root) { Stock::CorporateActionRebuilder.new(area: Stock::SZSTK).call(["sz000001"]) }

      assert_equal 1, report.stocks
      assert_equal 1, report.events
      # A ten-for-ten bonus halves the price, so the factor doubles.
      assert_in_delta 2.0, StockCorporateAction.find_by!(stock: "sz000001").factor, 1e-12
    end
  end

  test "records an adjusted move no board would allow" do
    Dir.mktmpdir do |root|
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 5.0],
        [Date.new(2026, 1, 7), 5.0]
      ])

      report = with_data_root(root) { Stock::CorporateActionRebuilder.new(area: Stock::SZSTK).call(["sz000001"]) }

      assert_equal 1, report.anomalies.size
      assert_equal 1, StockPriceAnomaly.where(stock: "sz000001").count
      anomaly = StockPriceAnomaly.find_by!(stock: "sz000001")
      assert_equal Date.new(2026, 1, 6), anomaly.date
      assert_in_delta -50.0, anomaly.change_pct, 1e-9
    end
  end

  test "an adjusted series leaves nothing to flag" do
    Dir.mktmpdir do |root|
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 5.0],
        [Date.new(2026, 1, 7), 5.0]
      ])
      store_event

      with_data_root(root) { Stock::CorporateActionRebuilder.new(area: Stock::SZSTK).call(["sz000001"]) }

      assert_empty StockPriceAnomaly.where(stock: "sz000001")
    end
  end

  test "a stock with no events keeps no factor and is flagged instead" do
    Dir.mktmpdir do |root|
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 10.1]
      ])

      report = with_data_root(root) { Stock::CorporateActionRebuilder.new(area: Stock::SZSTK).call(["sz000001"]) }

      assert_equal 0, report.events
      assert_empty StockPriceAnomaly.where(stock: "sz000001")
    end
  end

  test "re-running replaces the flagged days instead of adding to them" do
    Dir.mktmpdir do |root|
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 5.0]
      ])
      with_data_root(root) { Stock::CorporateActionRebuilder.new(area: Stock::SZSTK).call(["sz000001"]) }
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 10.1]
      ])
      with_data_root(root) { Stock::CorporateActionRebuilder.new(area: Stock::SZSTK).call(["sz000001"]) }

      assert_empty StockPriceAnomaly.where(stock: "sz000001")
    end
  end

  test "a fetched event set is used instead of the stored one" do
    Dir.mktmpdir do |root|
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 5.0]
      ])
      events = {
        "sz000001" => [
          { date: Date.new(2026, 1, 6), category: Stock::TdxQuote::CATEGORY_EX_RIGHTS,
            cash: 0.0, bonus: 10.0, rights: 0.0, rights_price: 0.0, resize: 0.0 }
        ]
      }

      report = with_data_root(root) do
        Stock::CorporateActionRebuilder.new(area: Stock::SZSTK, events_by_stock: events).call(["sz000001"])
      end

      assert_equal 1, report.events
      assert_in_delta 2.0, StockCorporateAction.find_by!(stock: "sz000001").factor, 1e-12
      assert_empty StockPriceAnomaly.where(stock: "sz000001")
    end
  end
end
