# What the reader has to do in the next month, gathered from everything the
# allocation page already knows: auto-investment debits, maturing deposits,
# rebalancing, stale amounts, deposit insurance, and whether the funds being
# bought still pass the fund checkup.
#
# Each item is an action (something to do) or a check that came out fine.
# A month with no actions is the normal case, and the page says so.
class MonthlyChecklist
  HORIZON = 30            # days ahead an upcoming event counts as this month's
  FUND_DATA_MAX_AGE = 14  # days before the fund checkup data is stale

  Item = Struct.new(:level, :key, :args, :on, keyword_init: true) do
    def action? = level == :action
  end

  def initialize(portfolio, today: Date.current, fund_data: nil, tracked: nil)
    @portfolio = portfolio
    @today = today
    @fund_data = fund_data
    @tracked = tracked || portfolio.tracked_plans(today)
  end

  def items
    @items ||= begin
      list = []
      plan_items(list)
      maturity_items(list)
      rebalance_items(list)
      stale_items(list)
      insurance_items(list)
      fund_items(list)
      fund_data_items(list)
      # actions first, soonest first; same-day items keep the order they were added
      list.each_with_index.sort_by { |i, n| [i.action? ? 0 : 1, i.on || Date.new(9999), n] }.map(&:first)
    end
  end

  def actions = items.select(&:action?)

  # The soonest dated event beyond this month, for a quiet month's summary.
  def next_event
    dates = @tracked.filter_map { |_plan, r| r.next_date if r.next_date && r.next_date > horizon_end }
    dates += @portfolio.maturities.map(&:matures_on).select { |d| d > horizon_end }
    dates.min
  end

  private

  def horizon_end = @today + HORIZON

  def plan_items(list)
    # A debit a few days past still shows: the prices that would record it
    # may not have been refreshed yet.
    due = @tracked.select { |_plan, r| r.next_date && r.next_date.between?(@today - 7, horizon_end) }
    due.each do |plan, r|
      list << Item.new(level: :action, key: :debit, on: r.next_date,
                       args: { name: plan.name, date: r.next_date.iso8601, amount: plan.amount })
    end
    if due.any?
      list << Item.new(level: :action, key: :keep_cash, on: due.map { |_p, r| r.next_date }.min,
                       args: { amount: due.sum { |plan, _r| plan.amount } })
    end
    @tracked.each do |plan, r|
      list << Item.new(level: :ok, key: :plan_done, args: { name: plan.name }) if r.done
    end
  end

  def maturity_items(list)
    @portfolio.matured(@today).each do |h|
      list << Item.new(level: :action, key: :matured, on: h.matures_on,
                       args: { name: h.name, date: h.matures_on.iso8601, amount: h.amount })
    end
    @portfolio.maturities.select { |h| h.matures_on.between?(@today, horizon_end) }.each do |h|
      list << Item.new(level: :action, key: :maturing, on: h.matures_on,
                       args: { name: h.name, date: h.matures_on.iso8601, amount: h.amount })
    end
  end

  def rebalance_items(list)
    return if @portfolio.empty?

    if @portfolio.needs_rebalance?(@today)
      list << Item.new(level: :action, key: :rebalance, args: {})
    else
      list << Item.new(level: :ok, key: :on_target, args: { band: @portfolio.band })
    end
  end

  def stale_items(list)
    stale = @portfolio.stale_holdings(@today)
    return if stale.empty?

    list << Item.new(level: :action, key: :stale, args: { names: stale.map(&:name), days: Portfolio::STALE_DAYS })
  end

  def insurance_items(list)
    @portfolio.over_insured.each do |institution, sum|
      list << Item.new(level: :action, key: :over_insured, args: { institution: institution, amount: sum })
    end
  end

  # The funds being bought, checked again against today's fund data: a fee
  # rise, a purchase limit or a shrinking fund shows up here without the
  # reader having to look it up.
  def fund_items(list)
    return unless @fund_data&.available?

    codes = @portfolio.plans.filter_map(&:fund_code) +
            @portfolio.holdings.select { |h| h.bucket == "stock" }.filter_map(&:code)
    codes.uniq.each do |code|
      fund = @fund_data.find(code) or next
      check = @fund_data.check(fund)
      next if check.verdict == :info

      if check.verdict == :good
        list << Item.new(level: :ok, key: :fund_good, args: { code: code, name: fund.name })
      else
        worst = check.reasons.find { |r| r.verdict == check.verdict }
        list << Item.new(level: :action, key: :fund_flagged,
                         args: { code: code, name: fund.name, verdict: check.verdict, reason: worst })
      end
    end
  end

  def fund_data_items(list)
    return if @fund_data.nil? || @portfolio.plans.empty?

    fetched = @fund_data.details_at.presence && (Date.iso8601(@fund_data.details_at[0, 10]) rescue nil)
    if fetched.nil? || (@today - fetched).to_i > FUND_DATA_MAX_AGE
      list << Item.new(level: :action, key: :fund_data_old, args: { date: fetched&.iso8601 })
    end
  end
end
