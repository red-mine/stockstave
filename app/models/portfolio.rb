require "bigdecimal"
require "json"
require "securerandom"

# The reader's own holdings and the stock/bond/cash mix they want to keep.
#
# This is private money, so it lives in its own JSON file under storage/
# (git-ignored) and never in the stock database: that database is mirrored
# every night into the public preview. The routes that read it are not
# mounted in production, which is what the public preview runs.
#
# docs/allocation.md is why the page exists: across five studies no stock-
# picking rule beat the market, while a fixed mix rebalanced once a year did
# as well as holding stocks alone with half the fall. The page keeps that
# discipline: it shows how far the holdings have drifted from the mix and
# what to buy or sell to bring them back.
class Portfolio
  BUCKETS = %w[cash bond stock].freeze
  DEFAULT_TARGETS = { "cash" => 40, "bond" => 50, "stock" => 10 }.freeze
  DEFAULT_BAND = 5            # percentage points of drift before acting
  DEFAULT_INTERVAL = 12       # months between scheduled rebalances
  STALE_DAYS = 31             # an amount older than this is probably out of date

  class Invalid < StandardError; end

  Holding = Struct.new(:id, :name, :code, :bucket, :amount, :updated_on, keyword_init: true) do
    def to_h
      { "id" => id, "name" => name, "code" => code, "bucket" => bucket,
        "amount" => amount.to_s("F"), "updated_on" => updated_on&.iso8601 }
    end
  end

  # One row of the comparison: where a bucket is against where it should be.
  Row = Struct.new(:bucket, :amount, :actual, :target, :gap, :trade, keyword_init: true)

  attr_reader :path, :targets, :band, :interval, :last_rebalanced_on, :holdings

  def self.default_path
    ENV.fetch("STOCK_PORTFOLIO_PATH") { Rails.root.join("storage", "portfolio.json").to_s }
  end

  def self.load(path = default_path)
    data = File.file?(path) ? JSON.parse(File.read(path)) : {}
    new(path, data)
  end

  def initialize(path, data = {})
    @path = path
    @targets = BUCKETS.to_h { |b| [b, Integer(data.dig("targets", b) || DEFAULT_TARGETS[b])] }
    @band = Integer(data["band"] || DEFAULT_BAND)
    @interval = Integer(data["interval"] || DEFAULT_INTERVAL)
    @last_rebalanced_on = parse_date(data["last_rebalanced_on"])
    @holdings = Array(data["holdings"]).map do |h|
      Holding.new(id: h["id"], name: h["name"], code: h["code"].presence, bucket: h["bucket"],
                  amount: BigDecimal(h["amount"].to_s), updated_on: parse_date(h["updated_on"]))
    end
  end

  def empty? = holdings.empty?

  def total = holdings.sum(BigDecimal("0"), &:amount)

  def bucket_amount(bucket)
    holdings.select { |h| h.bucket == bucket }.sum(BigDecimal("0"), &:amount)
  end

  # Percentages are of the current total; a trade is what brings the bucket
  # back to its target at that total (positive buys, negative sells).
  def rows
    sum = total
    BUCKETS.map do |b|
      amount = bucket_amount(b)
      actual = sum.zero? ? 0.0 : (amount / sum * 100).to_f
      target_amount = sum * targets[b] / 100
      Row.new(bucket: b, amount: amount, actual: actual, target: targets[b],
              gap: actual - targets[b], trade: (target_amount - amount).round(0))
    end
  end

  def drifted? = !empty? && rows.any? { |r| r.gap.abs > band }

  def due_on = last_rebalanced_on&.>>(interval)

  def overdue?(today = Date.current) = !empty? && due_on.present? && today >= due_on

  def needs_rebalance?(today = Date.current) = drifted? || overdue?(today)

  def stale_holdings(today = Date.current)
    holdings.select { |h| h.updated_on.nil? || (today - h.updated_on).to_i > STALE_DAYS }
  end

  # New money goes to the buckets that are short of target first, so saving
  # alone moves the mix back without selling anything; what is left after
  # every bucket reaches its target is split at the target weights.
  def split(money)
    money = BigDecimal(money.to_s) rescue raise(Invalid, "amount")
    raise Invalid, "amount" unless money.positive?

    after = total + money
    short = BUCKETS.to_h { |b| [b, [after * targets[b] / 100 - bucket_amount(b), 0].max] }
    need = short.values.sum
    parts = if need >= money
              short.transform_values { |s| money * s / need }
            else
              rest = money - need
              short.to_h { |b, s| [b, s + rest * targets[b] / 100] }
            end
    parts.transform_values { |v| v.round(0) }
  end

  def update_settings(targets:, band:, interval:)
    values = BUCKETS.to_h { |b| [b, Integer(targets.fetch(b), 10)] }
    raise Invalid, "targets" unless values.values.all? { |v| v.between?(0, 100) } && values.values.sum == 100

    band = Integer(band, 10)
    interval = Integer(interval, 10)
    raise Invalid, "band" unless band.between?(1, 50)
    raise Invalid, "interval" unless interval.between?(1, 60)

    @targets, @band, @interval = values, band, interval
    save
  rescue ArgumentError, TypeError, KeyError
    raise Invalid, "targets"
  end

  def add_holding(name:, code:, bucket:, amount:, today: Date.current)
    holdings << build_holding(SecureRandom.hex(6), name, code, bucket, amount, today)
    save
  end

  def update_holding(id, name:, code:, bucket:, amount:, today: Date.current)
    index = holdings.index { |h| h.id == id } or raise Invalid, "holding"
    holdings[index] = build_holding(id, name, code, bucket, amount, today)
    save
  end

  def remove_holding(id)
    holdings.reject! { |h| h.id == id } or raise Invalid, "holding"
    save
  end

  def record_rebalance(today = Date.current)
    @last_rebalanced_on = today
    save
  end

  def to_h
    { "targets" => targets, "band" => band, "interval" => interval,
      "last_rebalanced_on" => last_rebalanced_on&.iso8601, "holdings" => holdings.map(&:to_h) }
  end

  # Written to a sibling file and renamed over the old one, so a crash
  # mid-write leaves the previous version rather than half a file.
  def save
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.#{SecureRandom.hex(4)}.tmp"
    File.write(temp, JSON.pretty_generate(to_h))
    File.rename(temp, path)
    self
  end

  private

  def build_holding(id, name, code, bucket, amount, today)
    name = name.to_s.strip
    raise Invalid, "name" if name.empty? || name.length > 60
    raise Invalid, "bucket" unless BUCKETS.include?(bucket.to_s)

    value = BigDecimal(amount.to_s.delete(",").strip)
    raise Invalid, "amount" if value.negative? || value > 1_000_000_000

    Holding.new(id: id, name: name, code: code.to_s.strip.presence&.first(12), bucket: bucket.to_s,
                amount: value.round(2), updated_on: today)
  rescue ArgumentError, TypeError
    raise Invalid, "amount"
  end

  def parse_date(value)
    value.present? ? Date.iso8601(value.to_s) : nil
  rescue Date::Error
    nil
  end
end
