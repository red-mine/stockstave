module Stock
  # The signal-history page used to run SignalPerformance and
  # StrategySimulation for every request. Each one replays the whole saved
  # snapshot history, so a visitor paid for a nightly report over and over.
  #
  # This service computes that report once after the data changes and stores
  # the rendered measurements in the database. The page reads the stored
  # object; when it is missing or its inputs have moved, the same request
  # rebuilds it rather than serving a stale claim.
  class SignalHistoryReport
    SCHEMA_VERSION = 1

    Result = Data.define(
      :area, :source_date, :generated_at, :price_basis,
      :performance, :simulation, :benchmark, :simulation_days, :benchmark_series
    )

    class << self
      def fetch(area)
        new(area).fetch
      end

      def rebuild(area)
        new(area).rebuild
      end

      def rebuild_all
        Stock::AREAS.to_h { |area| [area, rebuild(area)] }
      end
    end

    def initialize(area)
      @area = area
    end

    def fetch
      record = StockSignalHistoryReport.find_by(area: @area)
      return rebuild if record.nil? || !current?(record)

      restore(record)
    rescue JSON::ParserError, KeyError, TypeError, Date::Error
      rebuild
    end

    def rebuild
      performance = SignalPerformance.new(@area).call
      simulation = StrategySimulation.new(@area).call
      benchmark = if simulation.ready
        IndexBenchmark.new(@area, simulation.equity_curve.map(&:date)).call
      else
        empty_benchmark
      end
      price_basis = PriceAdjustment.basis_for(@area)

      record = StockSignalHistoryReport.find_or_initialize_by(area: @area)
      record.assign_attributes(
        schema_version: SCHEMA_VERSION,
        source_date: snapshot_source_date,
        inputs_updated_at: adjustment_inputs_updated_at,
        price_basis: price_basis.to_s,
        payload: JSON.generate(
          schema_version: SCHEMA_VERSION,
          price_basis: price_basis.to_s,
          performance: dump_performance(performance),
          simulation: dump_simulation(simulation),
          benchmark: dump_benchmark(benchmark),
          simulation_days: dump_simulation_days(simulation),
          benchmark_series: dump_benchmark_series(benchmark, simulation)
        ),
        generated_at: Time.current
      )
      record.save!

      restore(record)
    end

    private
      def current?(record)
        record.schema_version == SCHEMA_VERSION &&
          record.source_date == snapshot_source_date &&
          record.inputs_updated_at&.to_i == adjustment_inputs_updated_at&.to_i
      end

      def snapshot_source_date
        StockSignalSnapshot.where(area: @area).maximum(:signal_date)
      end

      # A dividend record moves the prices the report measures on, so the
      # cache is tied to the adjustment inputs as well as the signal dates.
      def adjustment_inputs_updated_at
        [
          StockCorporateAction.where(area: @area).maximum(:updated_at),
          StockPriceAnomaly.where(area: @area).maximum(:updated_at)
        ].compact.max
      end

      def restore(record)
        payload = JSON.parse(record.payload)
        unless payload["schema_version"] == SCHEMA_VERSION
          return rebuild
        end

        Result.new(
          area: @area,
          source_date: record.source_date,
          generated_at: record.generated_at,
          price_basis: record.price_basis.to_sym,
          performance: load_performance(payload.fetch("performance")),
          simulation: load_simulation(payload.fetch("simulation")),
          benchmark: load_benchmark(payload.fetch("benchmark")),
          simulation_days: load_simulation_days(payload.fetch("simulation_days")),
          benchmark_series: payload["benchmark_series"]
        )
      end

      def dump_performance(report)
        {
          ready: report.ready,
          dates: report.dates,
          horizon: report.horizon,
          baseline: report.baseline.to_h,
          cohorts: report.cohorts.map(&:to_h)
        }
      end

      def load_performance(payload)
        SignalPerformance::Report.new(
          ready: payload.fetch("ready"),
          dates: payload.fetch("dates"),
          horizon: payload.fetch("horizon"),
          baseline: SignalPerformance::Baseline.new(**symbolize(payload.fetch("baseline"))),
          cohorts: payload.fetch("cohorts").map do |cohort|
            SignalPerformance::Cohort.new(**symbolize(cohort))
          end
        )
      end

      def dump_simulation(result)
        {
          ready: result.ready,
          dates: result.dates,
          starting_cash: result.starting_cash,
          final_equity: result.final_equity,
          total_return: result.total_return,
          max_drawdown: result.max_drawdown,
          anomalous_trades: result.anomalous_trades,
          trades: result.trades.map do |trade|
            trade.to_h.merge(
              entry_date: trade.entry_date&.iso8601,
              exit_date: trade.exit_date&.iso8601
            )
          end,
          equity_curve: result.equity_curve.map do |point|
            { date: point.date.iso8601, equity: point.equity }
          end
        }
      end

      def load_simulation(payload)
        StrategySimulation::Result.new(
          ready: payload.fetch("ready"),
          dates: payload.fetch("dates"),
          starting_cash: payload.fetch("starting_cash"),
          final_equity: payload.fetch("final_equity"),
          total_return: payload.fetch("total_return"),
          max_drawdown: payload.fetch("max_drawdown"),
          anomalous_trades: payload.fetch("anomalous_trades"),
          trades: payload.fetch("trades").map do |trade|
            StrategySimulation::Trade.new(
              stock: trade.fetch("stock"),
              entry_date: parse_date(trade["entry_date"]),
              exit_date: parse_date(trade["exit_date"]),
              entry_price: trade.fetch("entry_price"),
              exit_price: trade.fetch("exit_price"),
              return_pct: trade.fetch("return_pct"),
              reason: trade.fetch("reason"),
              weight: trade.fetch("weight"),
              zone: trade["zone"]
            )
          end,
          equity_curve: payload.fetch("equity_curve").map do |point|
            StrategySimulation::EquityPoint.new(
              date: parse_date(point.fetch("date")),
              equity: point.fetch("equity")
            )
          end
        )
      end

      def dump_benchmark(result)
        {
          available: result.available,
          index_code: result.index_code,
          total_return: result.total_return,
          prices: result.prices.to_h { |date, price| [date.iso8601, price] }
        }
      end

      def load_benchmark(payload)
        IndexBenchmark::Result.new(
          available: payload.fetch("available"),
          index_code: payload["index_code"],
          total_return: payload["total_return"],
          prices: payload.fetch("prices").to_h { |date, price| [parse_date(date), price] }
        )
      end

      def dump_simulation_days(simulation)
        return [] unless simulation.ready

        entries_by_date = simulation.trades.group_by(&:entry_date)
        exits_by_date = simulation.trades.group_by(&:exit_date)
        previous_equity = simulation.starting_cash

        simulation.equity_curve.map do |point|
          change_pct = ((point.equity - previous_equity) / previous_equity * 100).round(2)
          previous_equity = point.equity
          {
            date: point.date.iso8601,
            equity: point.equity,
            change_pct: change_pct,
            buys: entries_by_date[point.date]&.size || 0,
            sells: exits_by_date[point.date]&.size || 0
          }
        end
      end

      def load_simulation_days(payload)
        payload.map do |day|
          {
            date: parse_date(day.fetch("date")),
            equity: day.fetch("equity"),
            change_pct: day.fetch("change_pct"),
            buys: day.fetch("buys"),
            sells: day.fetch("sells")
          }
        end
      end

      def dump_benchmark_series(benchmark, simulation)
        return nil unless simulation.ready && benchmark.available

        dates = simulation.equity_curve.map(&:date)
        first_price = benchmark.prices[dates.first]
        return nil unless first_price.to_f.positive?

        dates.map { |date| [date.iso8601, (simulation.starting_cash * benchmark.prices[date] / first_price).round(2)] }
      end

      def empty_benchmark
        IndexBenchmark::Result.new(
          available: false, index_code: nil, total_return: nil, prices: {}
        )
      end

      def symbolize(payload)
        payload.to_h { |key, value| [key.to_sym, value] }
      end

      def parse_date(value)
        value && Date.iso8601(value)
      end
  end
end
