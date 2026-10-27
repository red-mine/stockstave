require "test_helper"
require "rake"

class DailyRefreshTaskTest < ActiveSupport::TestCase
  # Stands in for the importer: the refresh calls it with the stocks and a
  # budget and reads a report back.
  class StubImporter
    def initialize(report, &on_call)
      @report = report
      @on_call = on_call
    end

    def call(*_args, **_options)
      @on_call&.call
      @report
    end
  end

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("daily_refresh")
    Rake::Task["daily_refresh"].reenable
    Rake::Task["record_refresh_failure"].reenable if Rake::Task.task_defined?("record_refresh_failure")
    @refresh_directory = Dir.mktmpdir("daily-refresh-test")
  end

  teardown do
    Rake::Task["daily_refresh"].reenable
    Rake::Task["record_refresh_failure"].reenable if Rake::Task.task_defined?("record_refresh_failure")
    FileUtils.remove_entry(@refresh_directory) if File.exist?(@refresh_directory)
  end

  test "fetches the corporate actions for every market after the snapshots" do
    market = { healthy: true, source_date: Date.new(2026, 7, 31) }
    checker = Stock::DataStatus.allocate
    fetched = []

    checker.stub(:call, Stock::AREAS.index_with { market }) do
      Stock::DataStatus.stub(:new, ->(*) { checker }) do
        Stock::SignalSnapshot.stub(:capture!, 1) do
          importer = ->(area:) { StubImporter.new(empty_report) { fetched << area } }
          output, = capture_io { invoke_daily_refresh(importer: importer) }

          assert_match(/fetched 0 corporate action\(s\)/, output)
        end
      end
    end

    assert_equal Stock::AREAS, fetched
  end

  test "records snapshots for every market even when none need refreshing" do
    market = { healthy: true, source_date: Date.new(2026, 7, 31) }
    checker = Stock::DataStatus.allocate
    checker.stub(:call, Stock::AREAS.index_with { market }) do
      captured = []

      Stock::DataStatus.stub(:new, ->(*) { checker }) do
        Stock::SignalSnapshot.stub(:capture!, ->(area) { captured << area; 2 }) do
          output, = capture_io { invoke_daily_refresh }
          assert_match(/Captured rows: \{"bj" => 2, "sh" => 2, "sz" => 2\}/, output)
          assert_match(/Stored history rows:/, output)
        end
      end

      assert_equal Stock::AREAS, captured
    end
  end

  test "refreshes stale markets before recording snapshots" do
    healthy_market = { healthy: true, source_date: Date.new(2026, 7, 31) }
    stale_market = { healthy: false, source_date: Date.new(2026, 7, 30) }
    checker = Stock::DataStatus.allocate
    call_count = 0

    checker.stub(:call, -> {
      call_count += 1
      if call_count == 1
        {
          Stock::SZSTK => healthy_market,
          Stock::SHSTK => stale_market,
          Stock::BJSTK => healthy_market
        }
      else
        Stock::AREAS.index_with { healthy_market }
      end
    }) do
      refreshed = []

      Stock::DataStatus.stub(:new, ->(*) { checker }) do
        Stock::SignalSnapshot.stub(:capture!, 1) do
          Rake::Task[:refresh].stub(:invoke, ->(*areas) { refreshed.concat(areas) }) do
            invoke_daily_refresh
          end
        end
      end

      assert_equal [Stock::SHSTK], refreshed
      assert_equal 2, call_count
    end
  end

  test "fails instead of reporting success when a market captures no snapshots" do
    market = { healthy: true, source_date: Date.new(2026, 7, 31) }
    checker = Stock::DataStatus.allocate

    checker.stub(:call, Stock::AREAS.index_with { market }) do
      Stock::DataStatus.stub(:new, ->(*) { checker }) do
        capture = ->(area) { area == Stock::BJSTK ? 0 : 1 }
        Stock::SignalSnapshot.stub(:capture!, capture) do
          error = assert_raises(SystemExit) { capture_io { invoke_daily_refresh } }
          assert_equal 1, error.status
        end
      end
    end
  end

  test "records a failed status when the runner aborts before the Rails stage" do
    refresh_run = Stock::RefreshRun.new(
      lock_path: File.join(@refresh_directory, "refresh.lock"),
      status_path: File.join(@refresh_directory, "status.json"),
      scheduled_status_path: File.join(@refresh_directory, "scheduled-status.json")
    )
    ENV["STOCK_REFRESH_ERROR"] = "TongdaXin data update failed (exit code 1)"

    Stock::RefreshRun.stub(:new, ->(*) { refresh_run }) do
      output, = capture_io { Rake::Task["record_refresh_failure"].invoke }
      assert_match(/Recorded refresh failure: TongdaXin data update failed/, output)
    end

    status = JSON.parse(File.read(File.join(@refresh_directory, "status.json")))
    assert_equal "failed", status["state"]
    assert_equal "TongdaXin data update failed (exit code 1)", status["error"]
    assert status["finished_at"].present?
  ensure
    ENV.delete("STOCK_REFRESH_ERROR")
  end

  test "backs up before capturing snapshots even when no recalculation is needed" do
    market = { healthy: true, source_date: Date.new(2026, 7, 31) }
    checker = Stock::DataStatus.allocate
    events = []

    checker.stub(:call, Stock::AREAS.index_with { market }) do
      Stock::DataStatus.stub(:new, ->(*) { checker }) do
        Stock::SignalSnapshot.stub(:capture!, ->(_area) { events << :snapshot; 1 }) do
          capture_io { invoke_daily_refresh(backup: -> { events << :backup }) }
        end
      end
    end

    assert_equal :backup, events.first
    assert_equal 1, events.count(:backup)
  end

  private

  def invoke_daily_refresh(backup: -> {}, importer: nil)
    refresh_run = Stock::RefreshRun.new(
      lock_path: File.join(@refresh_directory, "refresh.lock"),
      status_path: File.join(@refresh_directory, "status.json")
    )
    # The refresh fetches the ex-rights records from the quote servers, and a
    # test has no business reaching the network: the step is stubbed here so
    # that it never depends on a server answering.
    build = importer || ->(area:) { StubImporter.new(empty_report) }
    Stock::RefreshRun.stub(:new, ->(*) { refresh_run }) do
      Rake::Task[:database_backup].stub(:invoke, backup) do
        Stock::CorporateActionImporter.stub(:new, build) do
          Rake::Task["daily_refresh"].invoke
        end
      end
    end
  end

  def empty_report
    Stock::CorporateActionImporter::Report.new(
      stocks: 0, events: 0, stored: 0, failures: {}, anomalies: []
    )
  end
end
