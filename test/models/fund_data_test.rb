require "test_helper"

class FundDataTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir }
  teardown { FileUtils.remove_entry(@dir) }

  def write(name, data) = File.write(File.join(@dir, name), JSON.generate(data))

  def detail(index, mgr, size, since)
    { "INDEXCODE" => index, "INDEXNAME" => "#{index}指数", "MGREXP" => mgr, "TRUSTEXP" => "0.05%",
      "SALESEXP" => "0.00%", "ENDNAV" => size, "ESTABDATE" => since }
  end

  def seed
    write("list.json", { "fetched_at" => "2026-10-29T18:00:00+08:00", "funds" => [
      %w[110020 易方达沪深300ETF联接A 指数型-股票], %w[007339 易方达沪深300ETF联接C 指数型-股票],
      %w[460300 华泰柏瑞沪深300ETF联接A 指数型-股票], %w[000001 华夏成长混合 混合型-偏股],
      %w[999999 某某沪深300ETF联接A 指数型-股票]
    ] })
    write("status.json", { "day" => "2026-10-29", "funds" => {
      "110020" => { "buy" => "开放申购" }, "007339" => { "buy" => "开放申购" },
      "460300" => { "buy" => "开放申购" }, "999999" => { "buy" => "暂停申购" }
    } })
    write("details.json", { "fetched_at" => "2026-10-29T19:00:00+08:00", "funds" => {
      "110020" => detail("000300", "0.15%", "15824191881", "2009-08-26"),
      "007339" => detail("000300", "0.15%", "15824191881", "2019-05-29").merge("SALESEXP" => "0.10%"),
      "460300" => detail("000300", "0.50%", "2196000000", "2012-05-29"),
      "999999" => detail("000300", "0.05%", "3000000000", "2015-01-01")
    } })
    FundData.new(@dir)
  end

  test "funds are joined from the list, the status and the details" do
    data = seed
    f = data.find("110020")

    assert_equal "开放申购", f.buy_status
    assert_equal BigDecimal("0.2"), f.total_fee
    assert_equal 5, data.count
    assert_equal 4, data.detailed_count
  end

  test "the cheapest fee on an index counts only funds open to buy" do
    data = seed

    # 999999 is cheaper but suspended, so 110020 sets the bar and qualifies
    assert_equal :good, data.check(data.find("110020")).verdict
    assert_includes data.check(data.find("460300")).reasons.map(&:key), :fee_high
  end

  test "a C share takes its age from the A share of the same fund" do
    data = seed

    assert_includes data.check(data.find("007339")).reasons.map(&:key), :age
  end

  test "funds on an index come best first, then cheapest, then largest" do
    # 110020 qualifies; the rest are cautions: 999999 is suspended (0.10%),
    # the C share 007339 carries a sales fee (0.30% a year), 460300 0.55%
    assert_equal %w[110020 999999 007339 460300], seed.on_index("000300").map(&:code)
  end

  test "search goes by code prefix or by name" do
    data = seed

    assert_equal %w[110020], data.search("1100").map(&:code)
    assert_equal %w[000001], data.search("华夏成长").map(&:code)
    assert_empty data.search("  ")
  end

  test "broad indexes are listed with how many funds track them" do
    assert_equal [["000300", "沪深300", 4]], seed.broad_indexes
  end

  test "no files means no data, not an error" do
    data = FundData.new(@dir)

    assert_not data.available?
    assert_nil data.find("110020")
  end
end
