require "test_helper"

class StockSignalHistoryReportTest < ActiveSupport::TestCase
  test "stores the report and restores it without replaying the snapshot history" do
    performance = performance_report
    simulation = simulation_report
    benchmark = benchmark_result

    result = with_report_computations(performance, simulation, benchmark) do
      Stock::SignalHistoryReport.rebuild(Stock::SZSTK)
    end

    assert_equal 1, StockSignalHistoryReport.count
    assert_equal Stock::SZSTK, result.area
    assert_equal :adjusted, result.price_basis

    cached = with_failing_computations do
      Stock::SignalHistoryReport.fetch(Stock::SZSTK)
    end

    assert_equal performance, cached.performance
    assert_equal simulation, cached.simulation
    assert_equal benchmark, cached.benchmark
    assert_equal 3, cached.simulation_days.size
    assert_equal Date.new(2026, 1, 1), cached.simulation_days.first[:date]
    assert_equal [100_000.0, 100_500.0, 102_000.0], cached.benchmark_series.map(&:last)
  end

  test "rebuilds after a new snapshot date enters the input history" do
    first = with_report_computations(performance_report, simulation_report, benchmark_result) do
      Stock::SignalHistoryReport.rebuild(Stock::SZSTK)
    end

    StockSignalSnapshot.create!(
      area: Stock::SZSTK, stock: "sz000001", signal_date: Date.new(2026, 2, 1), price: 10.0
    )
    refreshed_performance = performance_report(dates: 21)

    refreshed = with_report_computations(refreshed_performance, simulation_report, benchmark_result) do
      Stock::SignalHistoryReport.fetch(Stock::SZSTK)
    end

    assert_equal 20, first.performance.dates
    assert_equal 21, refreshed.performance.dates
    assert_equal 1, StockSignalHistoryReport.count
  end

  test "rebuilds a malformed cached payload instead of serving it" do
    with_report_computations(performance_report, simulation_report, benchmark_result) do
      Stock::SignalHistoryReport.rebuild(Stock::SZSTK)
    end
    StockSignalHistoryReport.find_by!(area: Stock::SZSTK).update!(payload: "{")

    result = with_report_computations(performance_report(dates: 22), simulation_report, benchmark_result) do
      Stock::SignalHistoryReport.fetch(Stock::SZSTK)
    end

    assert_equal 22, result.performance.dates
  end

  private
    def performance_report(dates: 20)
      cohort = Stock::SignalPerformance::Cohort.new(
        year_signal: "BUY5", lohas_signal: "BUY5", sample_size: 12,
        win_rate: 60.0, average_return: 1.2, average_drawdown: -2.1,
        trend_group: nil, baseline_return: 2.5, excess_return: -1.3, excess_dates: 10
      )
      baseline = Stock::SignalPerformance::Baseline.new(
        average_return: 2.5, dates: 10, sample_size: 100
      )
      Stock::SignalPerformance::Report.new(
        ready: true, dates: dates, horizon: 5, cohorts: [cohort], baseline: baseline
      )
    end

    def simulation_report
      dates = [Date.new(2026, 1, 1), Date.new(2026, 1, 2), Date.new(2026, 1, 5)]
      equity_curve = [
        Stock::StrategySimulation::EquityPoint.new(date: dates[0], equity: 100_000.0),
        Stock::StrategySimulation::EquityPoint.new(date: dates[1], equity: 101_000.0),
        Stock::StrategySimulation::EquityPoint.new(date: dates[2], equity: 103_000.0)
      ]
      trade = Stock::StrategySimulation::Trade.new(
        stock: "sz000001", entry_date: dates[0], exit_date: dates[2],
        entry_price: 10.0, exit_price: 10.3, return_pct: 3.0, reason: "sell",
        weight: 1.0, zone: -2
      )
      Stock::StrategySimulation::Result.new(
        ready: true, dates: dates.size, starting_cash: 100_000.0,
        final_equity: 103_000.0, total_return: 3.0, max_drawdown: -1.0,
        trades: [trade], equity_curve: equity_curve, anomalous_trades: 0
      )
    end

    def benchmark_result
      Stock::IndexBenchmark::Result.new(
        available: true, index_code: "sz399001", total_return: 2.0,
        prices: {
          Date.new(2026, 1, 1) => 100.0,
          Date.new(2026, 1, 2) => 100.5,
          Date.new(2026, 1, 5) => 102.0
        }
      )
    end

    def with_report_computations(performance, simulation, benchmark)
      Stock::SignalPerformance.stub(:new, ->(*) { Struct.new(:call).new(performance) }) do
        Stock::StrategySimulation.stub(:new, ->(*) { Struct.new(:call).new(simulation) }) do
          Stock::IndexBenchmark.stub(:new, ->(*) { Struct.new(:call).new(benchmark) }) do
            Stock::PriceAdjustment.stub(:basis_for, ->(*) { :adjusted }) do
              yield
            end
          end
        end
      end
    end

    def with_failing_computations
      Stock::SignalPerformance.stub(:new, ->(*) { flunk "performance was recomputed" }) do
        Stock::StrategySimulation.stub(:new, ->(*) { flunk "simulation was recomputed" }) do
          Stock::PriceAdjustment.stub(:basis_for, ->(*) { flunk "price basis was recomputed" }) do
            yield
          end
        end
      end
    end
end
