require "test_helper"

class FundFetcherTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @log = StringIO.new
  end

  teardown { FileUtils.remove_entry(@dir) }

  LIST = %(﻿var r = [["110020","YFDHS300","易方达沪深300ETF联接A","指数型-股票","YIFANGDA"],["000001","HXCZHH","华夏成长混合","混合型-偏股","HUAXIA"]];)
  STATUS = %(var db={chars:["0"],datas:[["110020","易方达沪深300ETF联接A","YFD","","","1.691","1.691","","","开放申购","开放赎回","","1","0","3036","","1","0.12%","0.12%","1","1.20%"]],count:["1"],record:"1",pages:"1",curpage:"1",indexsy:[],showday:["2026-10-29","2026-10-28"]})
  DETAIL = { "Datas" => { "FTYPE" => "指数型-股票", "ESTABDATE" => "2009-08-26", "ENDNAV" => "1", "INDEXCODE" => "000300",
                          "MGREXP" => "0.15%", "TRUSTEXP" => "0.05%", "SALESEXP" => "0.00%", "INVSTRA" => "long text" } }.to_json

  def fetcher(&http)
    FundFetcher.new(directory: @dir, http: http, sleeper: ->(_) {}, log: @log)
  end

  def answer(url)
    return LIST if url == FundFetcher::LIST_URL
    return STATUS if url.include?("Fund_JJJZ_Data")

    DETAIL
  end

  test "the list, the status and index-fund details are saved, nothing for active funds" do
    asked = []
    fetcher { |url| asked << url; answer(url) }.call

    data = FundData.new(@dir)
    f = data.find("110020")
    assert_equal "开放申购", f.buy_status
    assert_equal "0.12%", f.purchase_fee
    assert_equal "000300", f.index_code
    assert_nil f.detail["INVSTRA"], "long strategy text is not kept"
    assert_equal 1, asked.count { |u| u.include?("FundMNDetailInformation") }, "only the index fund is asked for"
    assert_equal "2026-10-29", data.status_day
  end

  test "a fund fetched within a week is not asked for again" do
    fetcher { |url| answer(url) }.call
    asked = []
    fetcher { |url| asked << url; answer(url) }.call

    assert_equal 0, asked.count { |u| u.include?("FundMNDetailInformation") }
  end

  test "a detail that keeps failing is reported and the rest is kept" do
    failed = fetcher { |url| url.include?("FundMNDetailInformation") ? raise("timeout") : answer(url) }.call

    assert_equal ["110020"], failed
    assert FundData.new(@dir).available?
  end

  test "an empty fund list is refused rather than saved" do
    assert_raises(FundFetcher::Error) { fetcher { |_| "var r = [];" }.call }
    assert_not File.exist?(File.join(@dir, "list.json"))
  end
end
