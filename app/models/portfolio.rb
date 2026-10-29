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
  DUE_SOON_DAYS = 7           # warn this many days before a holding matures
  # Deposit insurance (存款保险) covers principal plus interest up to this
  # much per depositor per bank. It covers deposits only, not funds or bonds.
  INSURED_LIMIT = BigDecimal("500000")

  class Invalid < StandardError; end

  # `institution` (the bank or platform) and `matures_on` (when a term
  # deposit or bond pays out) are optional: a money fund has neither date nor
  # deposit insurance, a term deposit has both.
  Holding = Struct.new(:id, :name, :code, :bucket, :amount, :updated_on, :institution, :matures_on,
                       keyword_init: true) do
    def to_h
      { "id" => id, "name" => name, "code" => code, "bucket" => bucket,
        "amount" => amount.to_s("F"), "updated_on" => updated_on&.iso8601,
        "institution" => institution, "matures_on" => matures_on&.iso8601 }
    end

    def days_left(today) = matures_on && (matures_on - today).to_i
  end

  # A monthly auto-investment (定投) into an index fund, valued by DcaTracker
  # on the ETF the fund invests in (`proxy`, e.g. sh510310 for 110020).
  Plan = Struct.new(:id, :name, :fund_code, :proxy, :amount, :day, :start_on, :months, keyword_init: true) do
    def to_h
      { "id" => id, "name" => name, "fund_code" => fund_code, "proxy" => proxy,
        "amount" => amount.to_s("F"), "day" => day, "start_on" => start_on.iso8601, "months" => months }
    end
  end

  DEFAULT_COMPARE_RATE = "1.5"  # percent a year a fixed-term deposit would pay instead

  # One row of the comparison: where a bucket is against where it should be.
  Row = Struct.new(:bucket, :amount, :actual, :target, :gap, :trade, keyword_init: true)

  attr_reader :path, :targets, :band, :interval, :last_rebalanced_on, :holdings, :plans, :compare_rate

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
                  amount: BigDecimal(h["amount"].to_s), updated_on: parse_date(h["updated_on"]),
                  institution: h["institution"].presence, matures_on: parse_date(h["matures_on"]))
    end
    @plans = Array(data["plans"]).map do |p|
      Plan.new(id: p["id"], name: p["name"], fund_code: p["fund_code"].presence, proxy: p["proxy"],
               amount: BigDecimal(p["amount"].to_s), day: Integer(p["day"]),
               start_on: Date.iso8601(p["start_on"]), months: Integer(p["months"]))
    end
    @compare_rate = BigDecimal((data["compare_rate"] || DEFAULT_COMPARE_RATE).to_s)
  end

  def add_plan(name:, fund_code:, proxy:, amount:, day:, start_on:, months:)
    name = name.to_s.strip
    raise Invalid, "name" if name.empty? || name.length > 60

    proxy = DcaTracker.normalize(proxy) or raise Invalid, "proxy"
    value = BigDecimal(amount.to_s.delete(",").strip) rescue raise(Invalid, "amount")
    raise Invalid, "amount" unless value.positive? && value <= 10_000_000

    day = Integer(day.to_s, 10) rescue raise(Invalid, "day")
    raise Invalid, "day" unless day.between?(1, 28)

    start = parse_date(start_on) or raise Invalid, "start_on"
    months = Integer(months.to_s, 10) rescue raise(Invalid, "months")
    raise Invalid, "months" unless months.between?(1, 600)

    plans << Plan.new(id: SecureRandom.hex(6), name: name, fund_code: fund_code.to_s.strip.presence&.first(12),
                      proxy: proxy, amount: value.round(2), day: day, start_on: start, months: months)
    save
  end

  def remove_plan(id)
    plans.reject! { |p| p.id == id } or raise Invalid, "plan"
    save
  end

  def update_compare_rate(rate)
    value = BigDecimal(rate.to_s.strip) rescue raise(Invalid, "compare_rate")
    raise Invalid, "compare_rate" unless value.between?(0, 20)

    @compare_rate = value
    save
  end

  # Dividend records of the plans' ETFs, cached beside the portfolio file so
  # the page never has to reach the quote servers to render. They are public
  # market data; they live here only because the plans that need them do.
  def events_path = File.join(File.dirname(path), "fund_events.json")

  def fund_events
    return {} unless File.file?(events_path)

    JSON.parse(File.read(events_path)).fetch("events", {}).transform_values do |rows|
      rows.map { |r| r.transform_keys(&:to_sym).merge(date: Date.iso8601(r["date"])) }
    end
  end

  def fund_events_fetched_at
    return nil unless File.file?(events_path)

    Time.iso8601(JSON.parse(File.read(events_path))["fetched_at"]) rescue nil
  end

  # Asks the quote servers for each plan ETF's dividend and split records.
  # Returns the codes that did not answer; what did answer is kept.
  # The quote-server client; a seam so tests never reach the network.
  def self.events_fetcher = ::Stock::CorporateActionFetcher.new

  def refresh_fund_events(fetcher: self.class.events_fetcher, deadline: Time.now + 60)
    codes = plans.map(&:proxy).uniq
    return [] if codes.empty?

    result = fetcher.call(codes, deadline: deadline)
    events = fund_events.merge(result.events.transform_values { |rows| rows.map(&:dup) })
    payload = { "fetched_at" => Time.now.iso8601,
                "events" => events.transform_values { |rows| rows.map { |r| r.merge(date: r[:date].iso8601) } } }
    write_atomically(events_path, JSON.pretty_generate(payload))
    result.failures.keys
  end

  def tracked_plans(today = Date.current)
    events = fund_events
    plans.map { |plan| [plan, DcaTracker.new(plan, events: events.fetch(plan.proxy, []), today: today, rate: compare_rate).call] }
  end

  # For each plan, {years => DcaTracker::Result or nil}: the plan had it
  # started that many years ago (DcaTracker.hindsight).
  def plan_hindsight(today = Date.current)
    events = fund_events
    plans.to_h do |plan|
      [plan.id, DcaTracker.hindsight(plan, events: events.fetch(plan.proxy, []), today: today, rate: compare_rate)]
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

  # Holdings with a maturity date, soonest first: what pays out when, so the
  # money for a known expense is there on the day.
  def maturities = holdings.select(&:matures_on).sort_by(&:matures_on)

  def due_soon(today = Date.current)
    maturities.select { |h| h.days_left(today).between?(0, DUE_SOON_DAYS) }
  end

  def matured(today = Date.current) = maturities.select { |h| h.days_left(today).negative? }

  # Institutions whose listed holdings add up to more than deposit insurance
  # covers. Only deposits are insured, so this is a prompt to check, not a
  # verdict: a fund held through a bank's app is not a deposit.
  def over_insured
    holdings.select(&:institution).group_by(&:institution)
            .transform_values { |hs| hs.sum(BigDecimal("0"), &:amount) }
            .select { |_, sum| sum > INSURED_LIMIT }
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

  def add_holding(today: Date.current, **fields)
    holdings << build_holding(SecureRandom.hex(6), today, **fields)
    save
  end

  def update_holding(id, today: Date.current, **fields)
    index = holdings.index { |h| h.id == id } or raise Invalid, "holding"
    holdings[index] = build_holding(id, today, **fields)
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
      "last_rebalanced_on" => last_rebalanced_on&.iso8601, "holdings" => holdings.map(&:to_h),
      "plans" => plans.map(&:to_h), "compare_rate" => compare_rate.to_s("F") }
  end

  # Written to a sibling file and renamed over the old one, so a crash
  # mid-write leaves the previous version rather than half a file.
  def save
    write_atomically(path, JSON.pretty_generate(to_h))
    self
  end

  private

  def write_atomically(target, content)
    FileUtils.mkdir_p(File.dirname(target))
    temp = "#{target}.#{SecureRandom.hex(4)}.tmp"
    File.write(temp, content)
    File.rename(temp, target)
  end

  def build_holding(id, today, name:, code:, bucket:, amount:, institution: nil, matures_on: nil)
    name = name.to_s.strip
    raise Invalid, "name" if name.empty? || name.length > 60
    raise Invalid, "bucket" unless BUCKETS.include?(bucket.to_s)

    value = BigDecimal(amount.to_s.delete(",").strip)
    raise Invalid, "amount" if value.negative? || value > 1_000_000_000

    institution = institution.to_s.strip.presence
    raise Invalid, "institution" if institution && institution.length > 40

    maturity = matures_on.presence && parse_date(matures_on)
    raise Invalid, "matures_on" if matures_on.present? && maturity.nil?

    Holding.new(id: id, name: name, code: code.to_s.strip.presence&.first(12), bucket: bucket.to_s,
                amount: value.round(2), updated_on: today, institution: institution, matures_on: maturity)
  rescue ArgumentError, TypeError
    raise Invalid, "amount"
  end

  def parse_date(value)
    value.present? ? Date.iso8601(value.to_s) : nil
  rescue Date::Error
    nil
  end
end
