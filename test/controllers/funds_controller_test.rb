require "test_helper"

class FundsControllerTest < ActionDispatch::IntegrationTest
  setup { @dir = Dir.mktmpdir }
  teardown { FileUtils.remove_entry(@dir) }

  def seed
    File.write(File.join(@dir, "list.json"), JSON.generate({ "fetched_at" => "2026-10-29T18:00:00+08:00", "funds" => [
      %w[110020 易方达沪深300ETF联接A 指数型-股票], %w[000001 华夏成长混合 混合型-偏股]
    ] }))
    File.write(File.join(@dir, "status.json"), JSON.generate({ "day" => "2026-10-29", "funds" => { "110020" => { "buy" => "开放申购" } } }))
    File.write(File.join(@dir, "details.json"), JSON.generate({ "fetched_at" => "2026-10-29T19:00:00+08:00", "funds" => {
      "110020" => { "INDEXCODE" => "000300", "INDEXNAME" => "沪深300指数", "MGREXP" => "0.15%", "TRUSTEXP" => "0.05%",
                    "SALESEXP" => "0.00%", "ENDNAV" => "15824191881", "ESTABDATE" => "2009-08-26", "JJGS" => "易方达基金" }
    } }))
  end

  def get_funds(**params)
    FundFetcher.stub(:directory, @dir) { get funds_path, params: params }
  end

  test "without data the page says how to fetch it" do
    get_funds

    assert_response :success
    assert_select "#funds-empty", text: /funds:refresh/
  end

  test "a fund code shows its checkup and reasons" do
    seed
    get_funds(q: "110020")

    assert_select "#fund-card h2", text: /易方达沪深300ETF联接A/
    assert_select "#fund-card .fund-good"
    assert_select "#fund-card .fund-reasons li", 5
  end

  test "an index lists its funds and an active fund is not recommended" do
    seed
    get_funds(index: "000300")
    assert_select "#fund-results tbody tr", 1
    assert_select "#fund-results tr[data-code='110020'] .fund-good"

    get_funds(q: "000001")
    assert_select "#fund-card .fund-avoid"
  end

  test "an unknown code says so" do
    seed
    get_funds(q: "123456")

    assert_select ".portfolio-status", text: /123456/
  end

  test "production refuses the page" do
    path = funds_path
    Rails.env.stub(:production?, true) { get path }

    assert_response :not_found
  end
end
