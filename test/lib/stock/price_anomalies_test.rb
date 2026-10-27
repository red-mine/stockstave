require "test_helper"

class Stock::PriceAnomaliesTest < ActiveSupport::TestCase
  test "a window that covers a flagged day is suspect" do
    StockPriceAnomaly.create!(
      area: Stock::SZSTK, stock: "sz000001", date: Date.new(2026, 1, 7),
      change_pct: -50.0, limit_pct: 10.5, detected_at: Time.current
    )

    anomalies = Stock::PriceAnomalies.for(Stock::SZSTK)

    assert anomalies.crosses?("sz000001", Date.new(2026, 1, 5), Date.new(2026, 1, 8))
    refute anomalies.crosses?("sz000001", Date.new(2026, 1, 5), Date.new(2026, 1, 6))
    refute anomalies.crosses?("sz000001", Date.new(2026, 1, 8), Date.new(2026, 1, 9))
    refute anomalies.crosses?("sz000002", Date.new(2026, 1, 5), Date.new(2026, 1, 8))
  end

  test "a market with no flagged days has no suspects" do
    refute Stock::PriceAnomalies.for(Stock::SZSTK).crosses?(
      "sz000001", Date.new(2026, 1, 5), Date.new(2026, 1, 8)
    )
  end
end
