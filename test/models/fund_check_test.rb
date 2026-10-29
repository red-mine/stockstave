require "test_helper"

class FundCheckTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 29)

  def fund(code: "110020", name: "易方达沪深300ETF联接A", type: "指数型-股票", buy: "开放申购", **detail)
    detail = { "INDEXCODE" => "000300", "INDEXNAME" => "沪深300指数", "MGREXP" => "0.15%", "TRUSTEXP" => "0.05%",
               "SALESEXP" => "0.00%", "ENDNAV" => "15824191881.54", "ESTABDATE" => "2009-08-26" }
             .merge(detail.transform_keys(&:to_s))
    FundData::Fund.new(code: code, name: name, type: type, status: buy && { "buy" => buy }, detail: detail)
  end

  def check(f, cheapest: BigDecimal("0.2"), established: nil)
    FundCheck.new(f, cheapest: cheapest, established: established, today: TODAY)
  end

  def keys(c) = c.reasons.map(&:key)

  test "a large, cheap, old, open broad index fund qualifies" do
    c = check(fund)

    assert_equal :good, c.verdict
    assert_equal %i[broad fee_low size age open], keys(c)
  end

  test "a sector index is a caution, whatever else is right" do
    c = check(fund(INDEXCODE: "399986", INDEXNAME: "中证银行指数"))

    assert_equal :caution, c.verdict
    assert_includes keys(c), :sector
  end

  test "an enhanced index fund is a caution" do
    assert_includes keys(check(fund(name: "某某沪深300指数增强A"))), :enhanced
  end

  test "fees are judged against the cheapest fund on the same index" do
    assert_equal :good, check(fund(MGREXP: "0.20%"), cheapest: BigDecimal("0.2")).verdict, "0.05 above is still the lowest tier"
    c = check(fund(MGREXP: "0.50%", TRUSTEXP: "0.10%"), cheapest: BigDecimal("0.2"))

    assert_equal :caution, c.verdict
    assert_equal({ fee: "0.6%", cheapest: "0.2%" }, c.reasons.find { |r| r.key == :fee_high }.args)
  end

  test "an overseas index is not held to an A-share fee" do
    cheapest = fund(type: "指数型-海外股票", INDEXCODE: "SPX", INDEXNAME: "标准普尔500指数", MGREXP: "0.50%", TRUSTEXP: "0.15%")
    dearer = fund(type: "指数型-海外股票", INDEXCODE: "SPX", INDEXNAME: "标准普尔500指数", MGREXP: "0.60%", TRUSTEXP: "0.20%")

    # 0.65% is the floor for S&P 500 funds, so it is the lowest tier there
    # even though an A-share index fund charges 0.2%
    assert_includes keys(check(cheapest, cheapest: BigDecimal("0.65"))), :fee_low
    assert_includes keys(check(dearer, cheapest: BigDecimal("0.65"))), :fee_high
  end

  test "small, young or restricted funds are cautions" do
    assert_includes keys(check(fund(ENDNAV: "150000000"))), :size_small
    assert_includes keys(check(fund(ENDNAV: "500000000"))), :size_medium
    assert_includes keys(check(fund(ESTABDATE: "2026-03-01"))), :age_new
    assert_includes keys(check(fund(ESTABDATE: "2024-10-31"))), :age_young
    assert_includes keys(check(fund(buy: "暂停申购"))), :restricted
  end

  test "a C share is dated by its fund's oldest share class and told about its sales fee" do
    c = check(fund(code: "007339", name: "易方达沪深300ETF联接C", ESTABDATE: "2019-05-29", SALESEXP: "0.10%"),
              cheapest: BigDecimal("0.2"), established: Date.new(2009, 8, 26))

    assert_includes keys(c), :age
    assert_includes keys(c), :c_class
  end

  test "an exchange-traded fund is noted, not marked down" do
    c = check(fund(code: "510300", name: "沪深300ETF", buy: nil))

    assert_equal :good, c.verdict
    assert_includes keys(c), :exchange
  end

  test "an actively managed equity fund is not recommended" do
    c = check(FundData::Fund.new(code: "000001", name: "华夏成长混合", type: "混合型-偏股", status: nil, detail: nil))

    assert_equal :avoid, c.verdict
    assert_equal [:active], keys(c)
  end

  test "bond and money funds are described, not judged" do
    bond = FundData::Fund.new(code: "1", name: "x", type: "债券型-中短债", status: nil, detail: nil)
    index = check(fund(type: "指数型-固收", INDEXCODE: "H11001", INDEXNAME: "中债综合指数"))

    assert_equal :info, check(bond).verdict
    assert_equal :info, index.verdict
    assert_includes keys(index), :bond_index
  end
end
