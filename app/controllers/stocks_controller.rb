class StocksController < ApplicationController
  STOCK_ID_PATTERN = /\A(?:(?<area>sz|sh|bj))?(?<code>\d{6})\z/
  STOCK_QUERY_PATTERN = /\A[a-z0-9]{1,8}\z/
  SIGNAL_FILTERS = %w[all buy sell watch].freeze
  RETURN_ANCHORS = %w[buy-candidates current-signals].freeze

  # GET /stocks or /stocks.json
  def index
    area    = stock_area
    @area   = area
    stock   = normalized_stock_query
    return render_bad_request if params[:stock].present? && stock.nil?

    encoded_area = STOCK_ID_PATTERN.match(stock.to_s)&.[](:area)
    if encoded_area.present? && encoded_area != area
      return redirect_to stocks_by_area_path(encoded_area, stock: stock, anchor: "current-signals")
    end

    @stock  = stock
    stave   = Stock::Stave.new(area, Stock::STAVE)
    @stocks_stavs, @stavs_date = stave.search(stock)
    @signal_filter = normalized_signal_filter
    unless stock
      @signal_counts = signal_group_counts(@stocks_stavs)
      @stocks_stavs = filtered_signals(@stocks_stavs, @signal_filter)
    end
    @buy_candidates = stock ? [] : stave.strongest_buy_candidates
    @candidate_fundamentals = StockFundamental.where(area: @area, stock: @buy_candidates.map(&:stock)).index_by(&:stock)
    @result_count = @stocks_stavs.count if stock
    refresh_run = Stock::RefreshRun.new
    @refresh_status = refresh_run.status
    @scheduled_refresh_status = refresh_run.scheduled_status
    @refresh_schedule = Stock::RefreshSchedule.new.status
  end

  def signal_guide
    @area = stock_area
    requested_filter = params[:return_signal].to_s
    @return_signal_filter = requested_filter if requested_filter.in?(SIGNAL_FILTERS) && requested_filter != "all"
  end

  def signal_history
    @area = stock_area
    # This report is precomputed after the nightly refresh and reread here.
    # Rebuilding it on request is the fallback for a missing or stale row, not
    # the normal path: the page used to replay the whole snapshot history for
    # every visitor.
    report = Stock::SignalHistoryReport.fetch(@area)
    @performance = report.performance
    @simulation = report.simulation
    # The returns are measured on adjusted prices when the corporate actions
    # that adjust them are loaded, and on raw prices when they are not. The
    # page says which, so a number is never read as something it is not.
    @price_basis = report.price_basis
    if @simulation.ready
      @simulation_days = report.simulation_days
      @benchmark = report.benchmark
      @benchmark_series = report.benchmark_series if @benchmark.available
    end
    # The report's own readiness rule lives in SignalPerformance. Reading it
    # here rather than restating 20 keeps this card from claiming a market is
    # ready on a date the report itself would still refuse to run on.
    @minimum_dates = Stock::SignalPerformance::MINIMUM_DATES
    @history = Stock::AREAS.to_h do |area|
      snapshots = StockSignalSnapshot.where(area: area)
      dates = snapshots.distinct.count(:signal_date)
      [area, {
        rows: snapshots.count,
        stocks: snapshots.distinct.count(:stock),
        dates: dates,
        first_date: snapshots.minimum(:signal_date),
        latest_date: snapshots.maximum(:signal_date),
        ready: dates >= @minimum_dates
      }]
    end
  end

  def preview_health
    report = Stock::PreviewHealth.new.call
    render json: {
      status: report[:ready] ? "ready" : "incomplete",
      environment: Rails.env,
      log_level: Logger::SEV_LABEL[Rails.logger.level].downcase,
      date: report[:date],
      dates_aligned: report[:dates_aligned],
      markets: report[:markets]
    }, status: report[:ready] ? :ok : :service_unavailable
  end

  # GET /stocks/1 or /stocks/1.json
  def show
    area     = stock_area
    @area    = area
    stock_id = STOCK_ID_PATTERN.match(params[:stock].to_s.downcase)
    return render_not_found unless stock_id

    area    = stock_id[:area] || area
    stock   = "#{area}#{stock_id[:code]}"
    @stock  = stock
    @area   = area
    @return_anchor = params[:return_to].to_s.in?(RETURN_ANCHORS) ? params[:return_to].to_s : "current-signals"
    stave   = Stock::Stave.new(area, Stock::STAVE)
    return render_not_found unless stave.known_stock?(stock)

    @stave_lohas, @stave_years, @bolls_lohas, @bolls_years = stave.chart_data(stock)
    @stock_date, @market_date = stave.data_dates(stock)
    @trend_health = stave.trend_health(stock)
    @historical_data = @stock_date.present? && @market_date.present? && @stock_date < @market_date
    @signal_timeline = Stock::SignalTimeline.new(area, stock).call
    @fundamental = StockFundamental.find_by(area: @area, stock: @stock)
    @fundamental_quality = Stock::FundamentalsQuality.new(@fundamental).call
    if @signal_timeline.any?
      current = @signal_timeline.first
      @current_decision = Stock::SignalFamily.classify(current.year_signal, current.lohas_signal)
    end
  end

  private
    def render_bad_request
      if request.format.json?
        render json: { error: t("error_pages.bad_request.api") }, status: :bad_request
      else
        render :bad_request, status: :bad_request
      end
    end

    def render_not_found
      if request.format.json?
        render json: { error: t("error_pages.not_found.api") }, status: :not_found
      else
        render :not_found, status: :not_found
      end
    end

    def stock_area
      params[:area].to_s.downcase.in?(supported_stock_areas) ? params[:area].downcase : Stock::SZSTK
    end

    def supported_stock_areas
      Stock::AREAS
    end

    def normalized_stock_query
      stock = params[:stock].to_s.strip.downcase
      return nil if stock.empty?
      return stock if STOCK_QUERY_PATTERN.match?(stock)
    end

    def normalized_signal_filter
      params[:signal].to_s.in?(SIGNAL_FILTERS) ? params[:signal].to_s : "all"
    end

    def filtered_signals(scope, filter)
      unless scope.respond_to?(:where)
        return scope if filter == "all"
        return scope.select { |record| signal_group(record) == filter }
      end

      case filter
      when "buy"
        scope.where(year_signal: Stock::SignalFamily::BUY, lohas_signal: Stock::SignalFamily::BUY)
      when "sell"
        scope.where(year_signal: Stock::SignalFamily::SELL)
          .or(scope.where(lohas_signal: Stock::SignalFamily::SELL))
      when "watch"
        # Spelled out rather than written as where.not: in SQL, NOT (x = 'SEL7')
        # is NULL rather than true when x is NULL, so a stock with one horizon
        # unrecorded was dropped here while SignalFamily.classify called it
        # watch. It showed under All and under no filter at all. Each test
        # below therefore treats NULL as "neither sell nor buy", as classify does.
        arel     = scope.arel_table
        not_sell = ->(name) { arel[name].not_in(Stock::SignalFamily::SELL).or(arel[name].eq(nil)) }
        not_buy  = ->(name) { arel[name].not_in(Stock::SignalFamily::BUY).or(arel[name].eq(nil)) }

        scope.where(
          not_sell.call(:year_signal)
            .and(not_sell.call(:lohas_signal))
            .and(not_buy.call(:year_signal).or(not_buy.call(:lohas_signal)))
        )
      else
        scope
      end
    end

    def signal_group(record)
      Stock::SignalFamily.classify(record.year_signal, record.lohas_signal)
    end

    def signal_group_counts(scope)
      %w[all buy sell watch].to_h do |filter|
        [filter, filtered_signals(scope, filter).count]
      end
    end
  end
