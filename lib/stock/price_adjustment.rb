module Stock
  # The back-adjustment factors that turn raw TongdaXin closes into the
  # prices a shareholder actually experienced.
  #
  # Each ex-rights event has a reference price
  #
  #   ref = (P * 10 - cash + rights * rights_price) / (10 + bonus + rights)
  #
  # (per ten shares, P = the close before the ex-date), and the adjusted
  # series is the raw close times the running product of P / ref: a
  # multiplicative back-adjustment, so every daily return equals the
  # shareholder's return. The event study adjusts the same way
  # (research/event_study/fetch_xdxr.py), and the app measures on the same
  # prices so the two agree.
  #
  # The factor is stored per event, so looking one up for a date is an index
  # read rather than a replay of the whole history.
  class PriceAdjustment
    # One corporate action and the factor it leaves behind.
    Event = Struct.new(
      :stock, :ex_date, :category, :cash, :bonus, :rights, :rights_price, :resize, :factor,
      keyword_init: true
    )

    # The A-share codes the event study's universe covers. The rule that
    # decides an impossible day rests on the daily price limit, and a fund or
    # a sector index does not have one -- a cross-border fund can gap on an
    # overseas market, and a sector index is not a security at all -- so those
    # codes are not judged by it.
    A_SHARE_PREFIXES = {
      "sz" => %w[sz00 sz30],
      "sh" => %w[sh60 sh68],
      "bj" => %w[bj43 bj83 bj87 bj88 bj92]
    }.freeze

    # The factor in force for a set of stocks.
    #
    # A report measures hundreds of stocks on one area, so the factors are
    # loaded once and asked per quote rather than read per quote.
    class Factors
      def initialize(events)
        @dates = {}
        @values = {}
        events.group_by(&:stock).each do |stock, rows|
          ordered = rows.sort_by { |row| row.ex_date }
          @dates[stock] = ordered.map(&:ex_date)
          @values[stock] = ordered.map { |row| row.factor.to_f }
        end
      end

      # The factor in force on a date: 1.0 until the stock's first event.
      #
      # An event is in force from its own ex-date, so the last event with an
      # ex-date on or before the day is the one that counts -- the same day
      # the event study applies it on.
      def factor_for(stock, date)
        dates = @dates[stock]
        return 1.0 if dates.nil?

        index = dates.bsearch_index { |ex_date| ex_date > date }
        index = dates.size if index.nil?
        return 1.0 if index.zero?

        @values[stock][index - 1]
      end

      # The price a shareholder saw: the raw close times the factor in force.
      def price(stock, date, raw_price)
        raw_price.to_f * factor_for(stock, date)
      end

      # Whether any stock carries a factor that moves its price. A report on
      # raw prices and a report on adjusted prices are different claims, so
      # the page has to be able to say which one it is making.
      def adjusted?
        @values.any? { |_stock, values| values.any? { |value| value != 1.0 } }
      end
    end

    class << self
      # The factors for one area's stocks, as a lookup.
      def factors_for(area, stocks)
        stocks = Array(stocks)
        return Factors.new([]) if stocks.empty?

        actions = StockCorporateAction.where(area: area, stock: stocks).order(:ex_date)
        Factors.new(actions.to_a)
      end

      # The price basis an area's returns are measured on: :adjusted when the
      # stocks being measured carry a factor that moves their price, :raw
      # otherwise. A report on raw prices and a report on adjusted prices are
      # different claims, so a page has to be able to say which one it makes.
      def basis_for(area, stocks = nil)
        stocks ||= StockSignalSnapshot.where(area: area).distinct.pluck(:stock)
        factors_for(area, stocks).adjusted? ? :adjusted : :raw
      end

      # The cumulative factor in force from each event's date, computed the
      # way the event study does: walk the closes, and at every event apply
      # its terms to the close before it.
      #
      # Events before the first close cannot change a return inside the
      # series, so they are skipped -- the same rule the study applies --
      # and the factor in force back then is still 1.0. An event after the
      # last close has not happened yet either, so it leaves the factor as it
      # stands. Every event gets an entry, so a stock's rows always say what
      # factor was in force on its ex-date.
      def factors_for_events(events, closes)
        return {} if events.empty? || closes.empty?

        # Sorted by date, and stably so that two events on the same day keep
        # the order the vendor sent them in: the study sorts the same way and
        # applies same-day events to the reference price one after another.
        pending = events.each_with_index.sort_by { |event, index| [event[:date], index] }.map(&:first)
        factors = {}
        running = 1.0
        index = 0

        while index < pending.size && pending[index][:date] <= closes.first[0]
          factors[pending[index][:date]] = running
          index += 1
        end

        closes.each_cons(2) do |(previous_date, previous_close), (date, _close)|
          applied = []
          while index < pending.size && pending[index][:date] <= date
            applied << pending[index]
            index += 1
          end
          next if applied.empty?

          price = previous_close
          applied.each { |event| price = reference_price(price, event) }
          running *= previous_close / price if price != previous_close && price.positive?
          applied.each { |event| factors[event[:date]] = running }
        end

        while index < pending.size
          factors[pending[index][:date]] = running
          index += 1
        end

        factors
      end

      # The factors of one stock, from its events and its own .day history.
      def factors_for_stock(area, stock, events)
        factors_for_events(events, DayFile.new(area, stock).closes)
      end

      # The price an ex-rights event leaves behind: the close before it,
      # carried through the event's terms.
      def reference_price(price, event)
        if event[:category] == ::Stock::TdxQuote::CATEGORY_EX_RIGHTS
          shares = 10 + event[:bonus].to_f + event[:rights].to_f
          return price unless shares.positive?

          (price * 10 - event[:cash].to_f + event[:rights].to_f * event[:rights_price].to_f) / shares
        elsif event[:resize].to_f.positive?
          price / event[:resize].to_f
        else
          price
        end
      end

      # The widest daily move a board allows, plus the slack the event study
      # allows for rounding (research/event_study/analyze.py, daily_limit).
      def daily_limit(stock)
        return 0.305 if stock.start_with?(::Stock::BJSTK)
        return 0.205 if stock.start_with?("sz30", "sh68")

        0.105
      end

      # Whether a code is an A share, the universe the event study's
      # impossible-day rule was written for.
      def a_share?(stock)
        prefixes = A_SHARE_PREFIXES[stock[0, 2]]
        return false if prefixes.nil?

        prefixes.any? { |prefix| stock.start_with?(prefix) }
      end

      # The adjusted daily moves no A-share can make.
      #
      # A move beyond the board's limit after adjustment means the factor is
      # wrong -- the vendor missed an ex-rights record, or dated one
      # differently -- and not that the market moved. The event study finds
      # the same days (analyze.py, impossible_days) and drops the returns
      # whose holding window crosses them.
      #
      # `series` is the stock's adjusted closes, oldest first; `first_date`
      # is the earliest day any stock in the market traded, because a stock
      # listed after that is exempt for its first five sessions: a new
      # listing is not bound by the daily limit the same way.
      #
      # Only A shares are judged: the rule rests on the daily price limit,
      # which a fund or a sector index does not have.
      def impossible_days(stock, series, first_date)
        return [] if series.size < 2 || !a_share?(stock)

        limit = daily_limit(stock)
        listed_late = series.first[0] > first_date

        series.each_with_index.filter_map do |(date, close), index|
          next if index.zero?
          next if listed_late && index < 5

          previous = series[index - 1][1]
          next unless previous.to_f.positive?

          change = close.to_f / previous - 1
          next unless change.abs > limit

          { date: date, change_pct: change * 100, limit_pct: limit * 100 }
        end
      end
    end
  end
end
