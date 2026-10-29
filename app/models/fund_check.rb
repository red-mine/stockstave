require "bigdecimal"

# One fund's checkup: a verdict and the reasons for it.
#
# The rules follow what this project found (docs/conclusion.md and
# docs/allocation.md): picking stocks did not beat the market, so an
# actively managed fund is not recommended; a broad-market index fund at the
# lowest fee its index allows, large enough and old enough not to be wound
# up, and open to buy, is what qualifies. Bond, money-market and other
# non-equity funds are described, not judged: the checkup is about where to
# put the stock part of an allocation.
class FundCheck
  VERDICTS = %i[good caution avoid info].freeze

  # Broad-market indexes, by the index code the fund data carries. Anything
  # else an index fund tracks is a sector or theme: one direction of the
  # market, with its risk concentrated there.
  BROAD = {
    # A shares, by size
    "000300" => "沪深300", "000905" => "中证500", "000852" => "中证1000", "000510" => "中证A500",
    "000906" => "中证800", "000016" => "上证50", "000903" => "中证A100", "930050" => "中证A50",
    "000010" => "上证180", "399330" => "深证100", "399001" => "深证成指", "000001" => "上证指数",
    "000985" => "中证全指", "932000" => "中证2000",
    "716567" => "MSCI中国A股", "718711" => "MSCI中国A股人民币", "746059" => "MSCI中国A50", "XIN9" => "富时中国A50",
    # A shares, by board: broad within the board, though the boards lean to growth sectors
    "399006" => "创业板指", "399673" => "创业板50", "000688" => "科创50", "000680" => "科创综指",
    "000698" => "科创100", "899050" => "北证50",
    # Hong Kong and the US
    "HSI" => "恒生指数", "HSCEI" => "恒生中国企业",
    "SPX" => "标普500", "NDX100" => "纳斯达克100", "DJIA" => "道琼斯工业"
  }.freeze

  ACTIVE_EQUITY = %w[股票型 混合型-偏股 混合型-灵活 混合型-平衡 QDII-普通股票 QDII-混合偏股
                     QDII-混合灵活 FOF-进取型 FOF-均衡型].freeze

  MIN_SIZE = BigDecimal("1000000000")      # 10亿: large enough to track well and stay open
  SMALL_SIZE = BigDecimal("200000000")     # 2亿: below this a fund risks being wound up
  MIN_YEARS = 3
  NEW_YEARS = 1
  FEE_SLACK = BigDecimal("0.05")           # percentage points above the cheapest fund on the index

  Reason = Struct.new(:verdict, :key, :args, keyword_init: true)

  attr_reader :fund, :verdict, :reasons

  # `cheapest` is the lowest total fee among funds on the same index;
  # `established` the earliest inception among the fund's share classes.
  def initialize(fund, cheapest: nil, established: nil, today: Date.current)
    @fund = fund
    @cheapest = cheapest
    @established = established || fund.established
    @today = today
    @reasons = []
    @verdict = judge
  end

  private

  def judge
    return judge_index if fund.index_fund? && fund.equity?
    return add(:avoid, :active) if ACTIVE_EQUITY.include?(fund.type)

    add(:info, fund.index_fund? ? :bond_index : :not_equity, type: fund.type.to_s)
    note_fee
    note_size
    :info
  end

  def judge_index
    if BROAD.key?(fund.index_code)
      add(:good, :broad, index: BROAD[fund.index_code])
    else
      add(:caution, :sector, index: fund.index_name.to_s)
    end
    add(:caution, :enhanced) if fund.enhanced?

    if fund.total_fee
      if @cheapest.nil? || fund.total_fee <= @cheapest + FEE_SLACK
        add(:good, :fee_low, fee: pct(fund.total_fee))
      else
        add(:caution, :fee_high, fee: pct(fund.total_fee), cheapest: pct(@cheapest))
      end
    end
    add(:info, :c_class, fee: pct(fund.sales_fee)) if fund.sales_fee&.positive?

    note_size(strict: true)
    note_age
    note_status
    @reasons.any? { |r| r.verdict == :caution } ? :caution : :good
  end

  def note_fee
    add(:info, :fee, fee: pct(fund.total_fee)) if fund.total_fee
  end

  def note_size(strict: false)
    size = fund.size
    return add(strict ? :caution : :info, :size_unknown) if size.nil?

    yi = format("%.1f", (size / 100_000_000).to_f)
    if size < SMALL_SIZE
      add(:caution, :size_small, size: yi)
    elsif strict && size < MIN_SIZE
      add(:caution, :size_medium, size: yi)
    else
      add(strict ? :good : :info, :size, size: yi)
    end
  end

  def note_age
    return add(:caution, :age_unknown) if @established.nil?

    years = (@today - @established).to_i / 365.25
    if years < NEW_YEARS
      add(:caution, :age_new, date: @established.iso8601)
    elsif years < MIN_YEARS
      add(:caution, :age_young, date: @established.iso8601)
    else
      add(:good, :age, date: @established.iso8601, years: years.floor)
    end
  end

  def note_status
    return add(:info, :exchange) if fund.exchange_traded?
    return add(:caution, :status_unknown) if fund.buy_status.nil?

    fund.buy_status == "开放申购" ? add(:good, :open) : add(:caution, :restricted, status: fund.buy_status)
  end

  def add(verdict, key, **args)
    @reasons << Reason.new(verdict: verdict, key: key, args: args)
    verdict
  end

  def pct(value) = "#{value.to_s('F').sub(/\.?0+\z/, '')}%"
end
