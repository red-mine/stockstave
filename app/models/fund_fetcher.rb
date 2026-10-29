require "json"
require "net/http"

# Downloads the public fund data the fund checkup (FundCheck) reads, from
# Tiantian Fund (天天基金, eastmoney.com), into storage/funds/:
#
#   list.json     every fund code with its name and type (one request)
#   status.json   purchase and redemption status and purchase fee of every
#                 open-ended fund (one request)
#   details.json  fees, size, inception date and tracked index, one request
#                 per index fund
#
# The details are fetched slowly (DELAY between requests) and saved as they
# arrive, so an interrupted run resumes where it stopped, and a fund fetched
# within MAX_AGE is not asked for again. These are someone else's servers:
# the pace is deliberately polite, and a change on their side will break
# this and nothing else.
class FundFetcher
  LIST_URL = "https://fund.eastmoney.com/js/fundcode_search.js".freeze
  STATUS_URL = "https://fund.eastmoney.com/Data/Fund_JJJZ_Data.aspx?t=1&lx=1&letter=&gsid=&text=&sort=zdf,desc&page=1,50000&feature=%7C&dt={dt}&atfc=&onlySale=0".freeze
  DETAIL_URL = "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNDetailInformation?FCODE={code}&deviceid=Wap&plat=Wap&product=EFund&version=2.0.0".freeze
  HEADERS = { "User-Agent" => "Mozilla/5.0", "Referer" => "https://fund.eastmoney.com/fund.html" }.freeze
  DETAIL_FIELDS = %w[FTYPE ESTABDATE ENDNAV FEGMRQ INDEXCODE INDEXNAME MGREXP TRUSTEXP SALESEXP JJGS].freeze
  DELAY = 0.4
  MAX_AGE = 7 * 24 * 3600
  SAVE_EVERY = 100

  class Error < StandardError; end

  def self.directory = ENV.fetch("STOCK_FUNDS_PATH") { Rails.root.join("storage", "funds").to_s }

  # Funds whose details are worth a request: the ones tracking an index.
  # An actively managed fund is judged by its type alone.
  def self.detailed?(type) = type.to_s.start_with?("指数型")

  def initialize(directory: self.class.directory, http: method(:get), sleeper: method(:sleep), log: $stdout)
    @directory = directory
    @http = http
    @sleeper = sleeper
    @log = log
  end

  def call(details: true, limit: nil)
    list = fetch_list
    fetch_status
    fetch_details(list, limit: limit) if details
  end

  def fetch_list
    body = @http.call(LIST_URL)
    rows = JSON.parse(body.sub(/\A﻿/, "")[/\[.*\]/m])
    funds = rows.map { |code, _abbr, name, type, _pinyin| [code, name, type] }
    raise Error, "fund list came back empty" if funds.empty?

    write("list.json", { "fetched_at" => Time.now.iso8601, "funds" => funds })
    @log.puts "list: #{funds.size} funds"
    funds
  end

  def fetch_status
    body = @http.call(STATUS_URL.sub("{dt}", (Time.now.to_f * 1000).to_i.to_s))
    datas = body[/datas:(\[.*\]),count:/m, 1] or raise Error, "status list has an unexpected shape"
    day = body[/showday:\["(\d{4}-\d{2}-\d{2})"/, 1]
    status = JSON.parse(datas).to_h do |r|
      [r[0], { "buy" => r[9], "sell" => r[10], "fee" => r[17].presence, "list_fee" => r[20].presence }]
    end
    write("status.json", { "fetched_at" => Time.now.iso8601, "day" => day, "funds" => status })
    @log.puts "status: #{status.size} funds (#{day})"
    status
  end

  def fetch_details(list, limit: nil)
    store = read("details.json") || { "funds" => {} }
    funds = store["funds"]
    now = Time.now
    todo = list.select { |code, _name, type| self.class.detailed?(type) }.map(&:first).reject do |code|
      at = funds.dig(code, "fetched_at")
      at && now - Time.iso8601(at) < MAX_AGE
    end
    todo = todo.first(limit) if limit
    @log.puts "details: #{todo.size} to fetch, #{funds.size} cached"

    failed = []
    todo.each_with_index do |code, i|
      detail = fetch_detail(code)
      detail ? funds[code] = detail : failed << code
      if ((i + 1) % SAVE_EVERY).zero?
        write("details.json", store.merge("fetched_at" => Time.now.iso8601))
        @log.puts "  #{i + 1}/#{todo.size}, #{failed.size} failed"
      end
      @sleeper.call(DELAY)
    end
    write("details.json", store.merge("fetched_at" => Time.now.iso8601))
    @log.puts "details: done, #{failed.size} failed#{failed.any? ? " (#{failed.first(10).join(', ')})" : ''}"
    failed
  end

  private

  def fetch_detail(code)
    3.times do |attempt|
      body = @http.call(DETAIL_URL.sub("{code}", code))
      data = JSON.parse(body)["Datas"]
      return nil if data.nil?   # the API knows no such fund

      return data.slice(*DETAIL_FIELDS).merge("fetched_at" => Time.now.iso8601)
    rescue StandardError => e
      @log.puts "  #{code}: #{e.class} #{e.message[0, 80]}" if attempt == 2
      @sleeper.call(2 * (attempt + 1))
    end
    nil
  end

  def get(url)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 60) do |http|
      response = http.get(uri.request_uri, HEADERS)
      raise Error, "#{uri.host} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body.force_encoding(Encoding::UTF_8)
    end
  end

  def read(name)
    path = File.join(@directory, name)
    File.file?(path) ? JSON.parse(File.read(path)) : nil
  end

  def write(name, data)
    FileUtils.mkdir_p(@directory)
    path = File.join(@directory, name)
    temp = "#{path}.#{SecureRandom.hex(4)}.tmp"
    File.write(temp, JSON.generate(data))
    File.rename(temp, path)
  end
end
