require "bigdecimal"
require "json"

# The fund data FundFetcher saved, joined per fund and checked (FundCheck).
#
# Read from storage/funds/ and kept in memory until a file changes, so a
# page view does not parse several megabytes of JSON again.
class FundData
  Fund = Struct.new(:code, :name, :type, :status, :detail, keyword_init: true) do
    def index_fund? = type.to_s.start_with?("指数型")
    # 指数型-其他 is mostly gold and commodities: not a stock index.
    def equity? = type.to_s.in?(%w[指数型-股票 指数型-海外股票])
    def enhanced? = name.to_s.include?("增强")
    def index_code = detail&.dig("INDEXCODE").presence
    def index_name = detail&.dig("INDEXNAME").presence
    def company = detail&.dig("JJGS")
    def buy_status = status&.dig("buy")
    def purchase_fee = status&.dig("fee")

    # Exchange-traded funds (ETFs) are not in the off-exchange status list:
    # they are bought through a securities account.
    def exchange_traded? = status.nil? && code.start_with?("51", "56", "58", "15")

    def established
      Date.iso8601(detail["ESTABDATE"]) if detail&.dig("ESTABDATE").present?
    rescue Date::Error
      nil
    end

    def size
      value = detail&.dig("ENDNAV")
      value.present? && value != "--" ? BigDecimal(value) : nil
    rescue ArgumentError
      nil
    end

    def fee(key)
      value = detail&.dig(key).to_s.delete("%")
      value.match?(/\A\d+(\.\d+)?\z/) ? BigDecimal(value) : nil
    end

    def sales_fee = fee("SALESEXP")

    # Management + custody + sales service, percent a year.
    def total_fee
      parts = %w[MGREXP TRUSTEXP SALESEXP].map { |k| fee(k) }
      parts[0] && parts[1] ? parts.compact.sum : nil
    end

    # Share classes of one fund differ only in the trailing letter.
    def family = name.to_s.sub(/[A-Z]\z/, "")
  end

  @cache = nil

  class << self
    def load(directory = FundFetcher.directory)
      stamp = %w[list.json status.json details.json].map { |f| File.mtime(File.join(directory, f)).to_f rescue 0 }
      @cache = nil unless @cache&.first == [directory, stamp]
      @cache ||= [[directory, stamp], new(directory)]
      @cache.last
    end
  end

  attr_reader :list_at, :status_day, :details_at

  def initialize(directory)
    list = read(directory, "list.json")
    status = read(directory, "status.json")
    details = read(directory, "details.json")
    @list_at = list&.dig("fetched_at")
    @status_day = status&.dig("day")
    @details_at = details&.dig("fetched_at")
    statuses = status&.dig("funds") || {}
    detail_rows = details&.dig("funds") || {}
    @funds = (list&.dig("funds") || []).to_h do |code, name, type|
      [code, Fund.new(code: code, name: name, type: type, status: statuses[code], detail: detail_rows[code])]
    end
    @cheapest = cheapest_by_index
    @established = earliest_by_family
    @checks = {}
  end

  def available? = @funds.any?
  def count = @funds.size
  def detailed_count = @funds.count { |_, f| f.detail }

  def find(code) = @funds[code.to_s.strip]

  def check(fund)
    @checks[fund.code] ||= FundCheck.new(fund, cheapest: @cheapest[fund.index_code],
                                               established: @established[fund.family])
  end

  # By code prefix or by any part of the name, best verdicts first.
  def search(query, limit: 50)
    q = query.to_s.strip
    return [] if q.empty?

    hits = if q.match?(/\A\d{1,6}\z/)
             @funds.values.select { |f| f.code.start_with?(q) }
           else
             @funds.values.select { |f| f.name.to_s.include?(q) }
           end
    sort(hits).first(limit)
  end

  # Every fund on an index, best verdict, then lowest fee, then largest.
  def on_index(index_code) = sort(@funds.values.select { |f| f.index_code == index_code })

  # The broad indexes the data has funds for, with how many.
  def broad_indexes
    counts = @funds.values.group_by(&:index_code).transform_values(&:size)
    FundCheck::BROAD.filter_map { |code, label| [code, label, counts[code]] if counts[code] }
  end

  def verdict_counts
    @funds.values.map { |f| check(f).verdict }.tally
  end

  private

  def sort(funds)
    order = FundCheck::VERDICTS.each_with_index.to_h
    funds.sort_by do |f|
      [order[check(f).verdict], f.total_fee || BigDecimal("99"), -(f.size || 0), f.code]
    end
  end

  # The lowest total fee on each index, among funds that can be bought: a
  # closed or suspended fund's fee is no help to someone choosing today.
  def cheapest_by_index
    @funds.values.select { |f| f.index_code && f.total_fee && (f.buy_status == "开放申购" || f.exchange_traded?) }
          .group_by(&:index_code).transform_values { |fs| fs.map(&:total_fee).min }
  end

  def earliest_by_family
    @funds.values.select(&:established).group_by(&:family).transform_values { |fs| fs.map(&:established).min }
  end

  def read(directory, name)
    path = File.join(directory, name)
    File.file?(path) ? JSON.parse(File.read(path)) : nil
  end
end
