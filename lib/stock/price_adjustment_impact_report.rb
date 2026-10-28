module Stock
  # What the price adjustment changed: the same measured return, computed on
  # the raw closes the signals are derived from and on the dividend- and
  # split-adjusted closes a shareholder would have seen.
  #
  # The report comes in two languages. The research notes it answers to are
  # Chinese (docs/event_study.md), while the code and the rest of the docs are
  # English -- and both texts are produced from one computation, so the two
  # files can never disagree about a number.
  class PriceAdjustmentImpactReport
    LANGUAGES = %w[en zh].freeze
    HORIZONS = [5, 20].freeze

    Event = Data.define(
      :stock, :ex_date, :close_before, :close_after, :raw_move, :factor, :adjusted_move
    )

    TRANSLATIONS = {
      "en" => {
        title: "Price adjustment impact",
        generated: "Generated %<time>s from the saved signal history.",
        intro: [
          "Both columns come from the same code -- `Stock::SignalPerformance` -- and differ only",
          "in the price basis: the raw TongdaXin closes the signals are derived from, and the",
          "dividend- and split-adjusted closes a shareholder would have seen. Everything else is",
          "identical: entry at the close after the signal date, the same-day model pool as the",
          "baseline, the date weighting, and the holding periods dropped for a flagged price."
        ],
        holding_period: "### %<horizon>d-day holding period",
        cohort_header: "| cohort | n | raw avg | adjusted avg | Δ avg | raw pool | adjusted pool | " \
                       "raw excess | adjusted excess | Δ excess |",
        cohort_rule: "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        model_pool: "Model pool: raw %<raw>s -> adjusted %<adjusted>s " \
                    "(%<dates>d days, %<observations>d observations).",
        events_heading: "### Ex-rights events inside the window (%<count>d)",
        largest_effect: "The largest single effect is %<stock>s on %<date>s: the quote moved " \
                         "%<raw>s and the shareholder's return was %<adjusted>s.",
        event_header: "| stock | ex-date | close before | close on/after | raw move | factor | " \
                      "adjusted move |",
        event_rule: "|---|---|---:|---:|---:|---:|---:|",
        method_heading: "## Method",
        method_items: [
          "- The factors are the ones in `stock_corporate_actions`: the ex-rights records fetched from",
          "  the TongdaXin quote servers and turned into the same back-adjustment the event study",
          "  computes (`research/event_study/fetch_xdxr.py`).",
          "- The flagged days in `stock_price_anomalies` are dropped from both sides.",
          "- Signals are derived from the raw close in both cases; only the returns differ."
        ],
        regenerate: "- Regenerate with `bundle exec rails \"price_adjustment_impact%<args>s\"`."
      },
      "zh" => {
        title: "复权影响对照",
        generated: "生成时间 %<time>s，数据来源为已保存的信号历史。",
        intro: [
          "两列数据来自同一份代码——`Stock::SignalPerformance`——差别只在价格口径：",
          "一个是信号所用的通达信原始收盘价，另一个是股东实际见到的、已作分红与拆股",
          "复权的收盘价。其余完全相同：信号日次一交易日收盘买入、与基线相同的当日模型池、",
          "日期加权，以及对被标记价格区间的持有期剔除。"
        ],
        holding_period: "### %<horizon>d 日持有期",
        cohort_header: "| 组合 | n | 原始均值 | 复权均值 | Δ 均值 | 原始池 | 复权池 | " \
                       "原始超额 | 复权超额 | Δ 超额 |",
        cohort_rule: "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        model_pool: "模型池：原始 %<raw>s -> 复权 %<adjusted>s" \
                    "（%<dates>d 个交易日，%<observations>d 次观测）。",
        events_heading: "### 窗口内的除权事件（%<count>d）",
        largest_effect: "影响最大的一笔是 %<stock>s 于 %<date>s：报价变动 %<raw>s，" \
                         "股东实际收益为 %<adjusted>s。",
        event_header: "| 股票 | 除权日 | 除权前收盘 | 除权日/后收盘 | 原始涨跌 | 因子 | 复权涨跌 |",
        event_rule: "|---|---|---:|---:|---:|---:|---:|",
        method_heading: "## 口径说明",
        method_items: [
          "- 因子取自 `stock_corporate_actions`：从通达信行情服务器取回的除权记录，",
          "  并按事件研究（`research/event_study/fetch_xdxr.py`）同样的回溯复权方式换算。",
          "- `stock_price_anomalies` 中被标记的交易日，两侧同样剔除。",
          "- 两种口径的信号都由原始收盘价推导，只有收益计算不同。"
        ],
        regenerate: "- 重新生成：`bundle exec rails \"price_adjustment_impact%<args>s\"`。"
      }
    }.freeze

    def initialize(lang: "en", output: nil, now: nil)
      @lang = lang.to_s
      raise ArgumentError, "Unknown language: #{@lang.inspect}" unless LANGUAGES.include?(@lang)

      @text = TRANSLATIONS.fetch(@lang)
      @output = output
      @now = now
    end

    def call
      lines = []
      lines << "# #{@text[:title]}"
      lines << ""
      lines << format(@text[:generated], time: timestamp)
      lines << ""
      lines.concat(@text[:intro])
      lines << ""

      # Inside `module Stock` the bare constant is the one meant: writing
      # `Stock::AREAS` here would resolve to the `Stock::Stock` model first.
      AREAS.each { |area| lines.concat(area_lines(area)) }
      lines << @text[:method_heading]
      lines << ""
      lines.concat(@text[:method_items])
      lines << format(@text[:regenerate], args: regenerate_args)
      lines
    end

    private

    def timestamp
      (@now || Time.current).utc.strftime("%Y-%m-%d %H:%M UTC")
    end

    # The command has to name the file it writes and, for anything but the
    # default, the language to write it in -- otherwise the report tells the
    # reader to regenerate it into a file that does not exist. Only the
    # argument is built here: the template already spells out the task.
    def regenerate_args
      return "" if @output.nil? || @output.empty?

      language = @lang == "en" ? "" : ",#{@lang}"
      "[#{@output}#{language}]"
    end

    def area_lines(area)
      window = StockSignalSnapshot.where(area: area).pluck(:signal_date).minmax
      return [] unless window.first

      lines = []
      lines << "## #{area.upcase} (#{window.first} .. #{window.last})"
      lines << ""

      HORIZONS.each { |horizon| lines.concat(holding_lines(area, horizon)) }

      events = ex_rights_events(area, window)
      lines.concat(event_lines(events)) unless events.empty?
      lines
    end

    def holding_lines(area, horizon)
      adjusted = SignalPerformance.new(area, horizon: horizon, adjusted: true).call
      raw = SignalPerformance.new(area, horizon: horizon, adjusted: false).call

      lines = []
      lines << format(@text[:holding_period], horizon: horizon)
      lines << ""
      lines << @text[:cohort_header]
      lines << @text[:cohort_rule]
      adjusted.cohorts.each do |cohort|
        match = raw.cohorts.find do |other|
          other.year_signal == cohort.year_signal && other.lohas_signal == cohort.lohas_signal &&
            other.trend_group == cohort.trend_group
        end
        lines << format("| %s + %s | %d | %s | %s | %s | %s | %s | %s | %s | %s |",
                        cohort.year_signal, cohort.lohas_signal, cohort.sample_size,
                        format_percent(match&.average_return), format_percent(cohort.average_return),
                        format_delta(match&.average_return, cohort.average_return),
                        format_percent(match&.baseline_return), format_percent(cohort.baseline_return),
                        format_percent(match&.excess_return), format_percent(cohort.excess_return),
                        format_delta(match&.excess_return, cohort.excess_return))
      end
      lines << ""
      lines << format(@text[:model_pool], raw: format_percent(raw.baseline.average_return),
                                          adjusted: format_percent(adjusted.baseline.average_return),
                                          dates: adjusted.baseline.dates,
                                          observations: adjusted.baseline.sample_size)
      lines << ""
      lines
    end

    def event_lines(events)
      lines = []
      lines << format(@text[:events_heading], count: events.size)
      lines << ""

      largest = events.max_by { |event| (event.raw_move.abs - event.adjusted_move.abs).abs }
      lines << format(@text[:largest_effect], stock: largest.stock, date: largest.ex_date,
                                           raw: format_percent(largest.raw_move),
                                           adjusted: format_percent(largest.adjusted_move))
      lines << ""
      lines << @text[:event_header]
      lines << @text[:event_rule]
      events.each do |event|
        lines << format("| %s | %s | %.2f | %.2f | %.2f%% | %.4f | %.2f%% |",
                        event.stock, event.ex_date, event.close_before, event.close_after,
                        event.raw_move, event.factor, event.adjusted_move)
      end
      lines << ""
      lines
    end

    # The ex-rights events inside the measured window, with the raw move they
    # caused and the move the adjustment leaves behind.
    def ex_rights_events(area, window)
      snapshots = StockSignalSnapshot.where(area: area).order(:signal_date).to_a
      dates = snapshots.map(&:signal_date).uniq
      closes = snapshots.index_by { |snapshot| [snapshot.stock, snapshot.signal_date] }
      factors = PriceAdjustment.factors_for(area, snapshots.map(&:stock).uniq)

      StockCorporateAction.where(area: area).where(ex_date: window.first..window.last)
                          .order(:ex_date, :stock).filter_map do |action|
        before_date = dates.select { |date| date < action.ex_date }.last
        after_date = dates.find { |date| date >= action.ex_date }
        next unless before_date && after_date

        before = closes[[action.stock, before_date]]&.price
        after = closes[[action.stock, after_date]]&.price
        next unless before.to_f.positive? && after.to_f.positive?

        raw_move = (after / before - 1) * 100
        adjusted_before = before * factors.factor_for(action.stock, before_date)
        adjusted_after = after * factors.factor_for(action.stock, after_date)
        adjusted_move = (adjusted_after / adjusted_before - 1) * 100

        Event.new(stock: action.stock, ex_date: action.ex_date.to_s,
                  close_before: before, close_after: after,
                  raw_move: raw_move.round(2), factor: action.factor,
                  adjusted_move: adjusted_move.round(2))
      end
    end

    def format_percent(value)
      value.nil? ? "n/a" : "#{value}%"
    end

    def format_delta(before, after)
      return "n/a" if before.nil? || after.nil?

      difference = after - before
      "#{difference >= 0 ? '+' : ''}#{difference.round(2)}pp"
    end
  end
end
