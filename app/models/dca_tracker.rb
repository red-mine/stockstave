require "bigdecimal"

# What a monthly auto-investment (定投) plan would be worth today.
#
# Off-exchange index funds (the ones bought in Alipay, e.g. 110020) have no
# TongdaXin prices, but each one puts its money into an exchange-traded ETF
# (110020 into 510310). So the plan is valued on that ETF's daily closes,
# carried through its dividends, which the feeder fund keeps and reinvests.
# The result is an estimate: the fund's own net value differs by its small
# extra fees and cash holding. The fund app's figure is the real one.
#
# Each scheduled month buys at the close of the first trading day on or
# after the scheduled date, after the purchase fee, the way a fund order
# placed before 15:00 is priced.
class DcaTracker
  PURCHASE_FEE = BigDecimal("0.0012")   # 1.2% list fee at the usual 1-in-10 discount

  Purchase = Struct.new(:date, :amount, :price, :units, keyword_init: true)
  Result = Struct.new(:purchases, :invested, :value, :as_of, :deposit_value, :next_date, :done,
                      :priced, :adjusted, :too_early, keyword_init: true) do
    def profit = value - invested
    def return_pct = invested.zero? ? 0.0 : (profit / invested * 100).to_f
    def versus_deposit = value - deposit_value
  end

  # A fund code on TongdaXin: its prices are stored at 1/1000 yuan, ten
  # times finer than a stock's, so the per-ten-share dividend terms only
  # apply after dividing by ten.
  def self.fund?(code) = code.start_with?("sh5", "sz1")

  # "510310" -> "sh510310": Shanghai ETFs start with 5, Shenzhen ones with
  # 15, 16 or 18. An off-exchange fund code such as 110020 is none of these,
  # so typing the fund's own code here is refused rather than misread.
  def self.normalize(code)
    code = code.to_s.strip.downcase
    return code if code.match?(/\A(sh|sz)\d{6}\z/)
    return "sh#{code}" if code.match?(/\A5\d{5}\z/)
    return "sz#{code}" if code.match?(/\A1[568]\d{4}\z/)

    nil
  end

  HINDSIGHT_YEARS = [1, 3, 5].freeze

  # The same plan had it started `years` ago and run every month since:
  # what it would be worth today. Answers "has this beaten a deposit?" from
  # history before the reader's own plan has bought anything. A horizon the
  # ETF's history does not reach is nil, never priced from a later close.
  def self.hindsight(plan, events: nil, today: Date.current, rate: BigDecimal("1.5"), years: HINDSIGHT_YEARS)
    years.to_h do |y|
      start = today << (12 * y)
      past = plan.dup.tap { |p| p.start_on = start; p.months = 12 * y }
      result = new(past, events: events, today: today, rate: rate).call
      [y, result.priced && !result.too_early && result.purchases.any? ? result : nil]
    end
  end

  # `events` is the ETF's dividend and split records; nil means they have
  # not been fetched yet, which is not the same as an ETF that never paid.
  def initialize(plan, events: nil, today: Date.current, rate: BigDecimal("1.5"))
    @plan = plan
    @events_known = !events.nil?
    @events = events || []
    @today = today
    @rate = rate
  end

  def call
    series = adjusted_closes
    return empty_result(priced: false) if series.empty?

    dates = series.map(&:first)
    # A plan that starts before the ETF listed would otherwise buy its first
    # months at a close from after they were due.
    return empty_result(priced: true, too_early: true) if scheduled_date(0) < dates.first

    last_date = dates.last
    purchases = []
    next_date = nil
    @plan.months.times do |k|
      scheduled = scheduled_date(k)
      if scheduled > @today || scheduled > last_date
        next_date = scheduled
        break
      end
      index = dates.bsearch_index { |d| d >= scheduled }
      date, price = series[index]
      amount = BigDecimal(@plan.amount.to_s)
      units = amount * (1 - PURCHASE_FEE) / BigDecimal(price.to_s)
      purchases << Purchase.new(date: date, amount: amount, price: price, units: units)
    end

    units = purchases.sum(BigDecimal("0"), &:units)
    Result.new(purchases: purchases,
               invested: purchases.sum(BigDecimal("0"), &:amount),
               value: (units * BigDecimal(series.last[1].to_s)).round(2),
               as_of: last_date,
               deposit_value: deposit_value(purchases, last_date),
               next_date: next_date,
               done: purchases.size >= @plan.months,
               priced: true,
               adjusted: @events_known,
               too_early: false)
  end

  private

  def scheduled_date(k)
    month = @plan.start_on >> k
    last_day = Date.new(month.year, month.month, -1).day
    Date.new(month.year, month.month, [@plan.day, last_day].min)
  end

  # The ETF's closes in yuan, times the dividend factor in force, so a
  # holder's value grows by each dividend as if it were reinvested.
  def adjusted_closes
    area = @plan.proxy[0, 2]
    scale = self.class.fund?(@plan.proxy) ? 10.0 : 1.0
    closes = ::Stock::DayFile.new(area, @plan.proxy).closes.map { |date, close| [date, close / scale] }
    return [] if closes.empty?

    factors = ::Stock::PriceAdjustment.factors_for_events(@events.uniq, closes)
    ex_dates = factors.keys.sort
    closes.map do |date, close|
      index = ex_dates.bsearch_index { |d| d > date } || ex_dates.size
      factor = index.zero? ? 1.0 : factors[ex_dates[index - 1]]
      [date, close * factor]
    end
  end

  # The same money in a fixed-term deposit at `rate` percent a year,
  # simple interest from each purchase to the valuation date.
  def deposit_value(purchases, as_of)
    purchases.sum(BigDecimal("0")) do |p|
      p.amount * (1 + @rate / 100 * (as_of - p.date).to_i / 365)
    end.round(2)
  end

  def empty_result(priced:, too_early: false)
    zero = BigDecimal("0")
    Result.new(purchases: [], invested: zero, value: zero, as_of: nil, deposit_value: zero,
               next_date: scheduled_date(0), done: false, priced: priced, adjusted: @events_known,
               too_early: too_early)
  end
end
