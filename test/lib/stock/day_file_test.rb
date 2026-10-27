require "test_helper"
require "tmpdir"

class Stock::DayFileTest < ActiveSupport::TestCase
  test "reads a stock's whole history from its .day file" do
    Dir.mktmpdir do |root|
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 10.5]
      ])

      closes = with_data_root(root) { Stock::DayFile.new("sz", "sz000001").closes }

      assert_equal [[Date.new(2026, 1, 5), 10.0], [Date.new(2026, 1, 6), 10.5]], closes
    end
  end

  test "a missing file reads as no history" do
    Dir.mktmpdir do |root|
      closes = with_data_root(root) { Stock::DayFile.new("sz", "sz999999").closes }

      assert_empty closes
    end
  end

  test "the first trading day comes from the first record" do
    Dir.mktmpdir do |root|
      write_day_file(root, "sz", "sz000001", [
        [Date.new(2026, 1, 5), 10.0],
        [Date.new(2026, 1, 6), 10.5]
      ])

      first = with_data_root(root) { Stock::DayFile.new("sz", "sz000001").first_date }

      assert_equal Date.new(2026, 1, 5), first
    end
  end

  test "a missing file has no first trading day" do
    Dir.mktmpdir do |root|
      first = with_data_root(root) { Stock::DayFile.new("sz", "sz999999").first_date }

      assert_nil first
    end
  end
end
