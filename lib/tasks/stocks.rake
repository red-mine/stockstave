def print_simulation(mode, result, area, detail: false)
  puts "\n## #{mode} sizing"
  puts "-" * 40

  unless result.ready
    puts "  No signal history available for #{area.upcase}."
    return
  end

  benchmark = Stock::IndexBenchmark.new(area, result.equity_curve.map(&:date)).call

  puts "Trading dates:     #{result.dates}"
  puts "Starting cash:     #{format('%.2f', result.starting_cash)}"
  puts "Final equity:      #{format('%.2f', result.final_equity)}"
  puts "Total return:      #{result.total_return}%"
  puts "Max drawdown:      #{result.max_drawdown}%"
  if benchmark.available
    puts "Benchmark (#{benchmark.index_code}): #{benchmark.total_return}% buy & hold (strategy #{(result.total_return - benchmark.total_return).round(2) >= 0 ? "+" : ""}#{(result.total_return - benchmark.total_return).round(2)}pp vs. index)"
  else
    puts "Benchmark:         no index data available for #{area.upcase}"
  end

  if result.trades.any?
    wins = result.trades.count { |trade| trade.return_pct.positive? }
    avg_hold = result.trades.sum { |trade| (trade.exit_date - trade.entry_date).to_i }.fdiv(result.trades.size)
    puts "Trades closed:     #{result.trades.size}"
    puts "Win rate:          #{(wins.fdiv(result.trades.size) * 100).round(2)}%"
    puts "Avg holding days:  #{avg_hold.round(1)}"
    if result.anomalous_trades.positive?
      puts "Flagged trades:    #{result.anomalous_trades} (cover a day whose adjusted move no board allows)"
    end
  else
    puts "No trades were closed."
  end
  return unless detail

  puts
  puts "Daily equity curve:"
  entries_by_date = result.trades.group_by(&:entry_date)
  exits_by_date = result.trades.group_by(&:exit_date)
  previous_equity = result.starting_cash
  result.equity_curve.each do |point|
    change_pct = ((point.equity - previous_equity) / previous_equity * 100).round(2)
    buys = entries_by_date[point.date]&.size || 0
    sells = exits_by_date[point.date]&.size || 0
    activity = []
    activity << "#{buys} buy#{'s' unless buys == 1}" if buys.positive?
    activity << "#{sells} sell#{'s' unless sells == 1}" if sells.positive?
    activity_note = activity.any? ? "  [#{activity.join(', ')}]" : ""
    sign = change_pct >= 0 ? "+" : ""
    puts "  #{point.date}: #{format('%.2f', point.equity)} (#{sign}#{change_pct}%)#{activity_note}"
    previous_equity = point.equity
  end
end

desc "lohas"
task :lohas, [:area, :days] => :environment do |task, args|
  area = unless args.area.nil? then args.area else Stock::SZSTK end
  days = unless args.days.nil? then args.days else Stock::LOHAS end
  stock = Stock::Stock.new(area, days)
  stock.models(StocksCoefsLoha)
  stock.staves(StocksCoefsLoha)
end

desc "years"
task :years, [:area, :days] => :environment do |task, args|
  area = unless args.area.nil? then args.area else Stock::SZSTK end
  days = unless args.days.nil? then args.days else Stock::YEARS end
  stock = Stock::Stock.new(area, days)
  stock.models(StocksCoefsYear)
  stock.staves(StocksCoefsYear)
end

desc "stave"
task :stave, [:area, :days] => :environment do |task, args|
  area = unless args.area.nil? then args.area else Stock::SZSTK end
  days = unless args.days.nil? then args.days else Stock::STAVE end
  stock = Stock::Stock.new(area, days)
  stave = Stock::Stave.new(area, days)
  stock.result
  stave.result
end

desc "Create and verify a retained backup of the active SQLite database"
task database_backup: :environment do
  connection = ActiveRecord::Base.connection
  database = ActiveRecord::Base.connection_db_config.database
  if connection.adapter_name == "SQLite" && database && File.file?(database)
    backup_dir = Rails.root.join("tmp", "backups")
    FileUtils.mkdir_p(backup_dir)
    backup = backup_dir.join("stock-#{Time.current.strftime('%Y%m%d-%H%M%S-%L')}.sqlite3")
    Stock::DatabaseBackup.new(connection: connection).call(backup)
    puts "Database backup: #{backup}"
    keep = ENV.fetch("STOCK_BACKUP_KEEP", "7").to_i
    pruned = Stock::DatabaseBackup.prune(backup_dir, keep: keep)
    puts "Pruned #{pruned} old backup(s); keeping the newest #{[keep, 1].max}" if pruned.positive?
  end
end

desc "Mirror the active database over the public preview's isolated database"
task mirror_preview_database: :environment do
  target = Rails.root.join("tmp", "ui-stock.sqlite3")
  unless target.file?
    puts "No public preview database at #{target}; nothing to mirror."
    next
  end

  Stock::DatabaseBackup.new.mirror_into(target.to_s)
  puts "Mirrored the active database into #{target}"
end

desc "Refresh analysis data for all markets (or a selected market list)"
task :refresh, [:area1, :area2, :area3] => :environment do |_task, args|
  supported_areas = Stock::AREAS
  areas = args.to_a.compact.map(&:strip).uniq
  areas = supported_areas if areas.empty?
  invalid_areas = areas - supported_areas
  abort "Unsupported market(s): #{invalid_areas.join(', ')}" unless invalid_areas.empty?

  missing_paths = areas.reject do |area|
    File.directory?(File.join(Stock.data_root, area, "lday"))
  end
  unless missing_paths.empty?
    abort "Missing TongdaXin data for: #{missing_paths.join(', ')} under #{Stock.data_root}"
  end

  Rake::Task[:database_backup].invoke

  areas.each do |area|
    puts "Refreshing #{area}..."
    lohas = Stock::Stock.new(area, Stock::LOHAS)
    lohas.models(StocksCoefsLoha)
    lohas.staves(StocksCoefsLoha)

    years = Stock::Stock.new(area, Stock::YEARS)
    years.models(StocksCoefsYear)
    years.staves(StocksCoefsYear)

    Stock::Stock.new(area, Stock::STAVE).result
    Stock::Stave.new(area, Stock::STAVE).result
    puts "Finished #{area}."
  end
end

desc "Fetch fundamentals (PE, PB, ROE, growth) from Eastmoney for a market (or all markets)"
task :fundamentals_refresh, [:area] => :environment do |_task, args|
  areas = args.area.present? ? [args.area] : Stock::AREAS
  unsupported = areas - Stock::AREAS
  abort "Unsupported market(s): #{unsupported.join(', ')}" unless unsupported.empty?

  puts "Fetching latest performance reports from Eastmoney..."
  reports = Stock::FundamentalsFetcher.fetch_reports(Stock::FundamentalsFetcher.transport)

  areas.each do |area|
    counts = Stock::FundamentalsFetcher.new(area).call(reports: reports)
    puts "#{area.upcase}: stocks=#{counts[:stocks]} upserted=#{counts[:upserted]} with_report=#{counts[:with_report]} skipped=#{counts[:skipped]}"
  end
end

desc "Fetch the ex-rights records that turn raw closes into shareholder prices"
task :corporate_actions_refresh, [:area] => :environment do |_task, args|
  areas = args.area.present? ? [args.area] : Stock::AREAS
  unsupported = areas - Stock::AREAS
  abort "Unsupported market(s): #{unsupported.join(', ')}" unless unsupported.empty?

  areas.each do |area|
    stocks = Stock::CorporateActionImporter.measured_stocks(area)
    puts "Fetching #{area.upcase} corporate actions for #{stocks.size} stock(s)..."
    report = Stock::CorporateActionImporter.new(area: area).call(stocks)

    puts "#{area.upcase}: stocks=#{report.stocks} events=#{report.events} stored=#{report.stored} " \
         "anomalies=#{report.anomalies.size} failed=#{report.failures.size}"
    report.failures.each { |stock, error| puts "  failed #{stock}: #{error}" }
    report.anomalies.first(20).each do |anomaly|
      puts "  anomaly #{anomaly[:stock]} #{anomaly[:date]}: #{anomaly[:change_pct].round(2)}% " \
           "(board limit #{anomaly[:limit_pct]}%)"
    end
    puts "  #{report.anomalies.size - [report.anomalies.size, 20].min} further anomalies not listed." if report.anomalies.size > 20
  end
end

desc "Recompute the adjustment factors and price anomalies from the stored corporate actions"
task :corporate_actions_rebuild, [:area] => :environment do |_task, args|
  areas = args.area.present? ? [args.area] : Stock::AREAS
  unsupported = areas - Stock::AREAS
  abort "Unsupported market(s): #{unsupported.join(', ')}" unless unsupported.empty?

  areas.each do |area|
    stocks = Stock::CorporateActionRebuilder.measured_stocks(area)
    report = Stock::CorporateActionRebuilder.new(area: area).call(stocks)
    puts "#{area.upcase}: stocks=#{report.stocks} events=#{report.events} stored=#{report.stored} " \
         "anomalies=#{report.anomalies.size}"
  end
end

desc "Report the stored corporate actions and the price anomalies they imply"
task corporate_actions_status: :environment do
  Stock::AREAS.each do |area|
    actions = StockCorporateAction.where(area: area)
    anomalies = StockPriceAnomaly.where(area: area)
    adjusted = actions.where.not(factor: 1.0).count
    puts "#{area.upcase}: events=#{actions.count} stocks=#{actions.distinct.count(:stock)} " \
         "with_factor=#{adjusted} anomalies=#{anomalies.count} " \
         "anomaly_stocks=#{anomalies.distinct.count(:stock)}"
    anomalies.order(:date).limit(20).each do |anomaly|
      puts "  #{anomaly.stock} #{anomaly.date}: #{anomaly.change_pct.round(2)}% (board limit #{anomaly.limit_pct}%)"
    end
  end
end

desc "Report TongdaXin source and generated-data health"
task data_status: :environment do
  checker = Stock::DataStatus.new
  report = checker.call

  report.each do |area, market|
    state = market[:healthy] ? "OK" : "INCOMPLETE"
    puts "#{area.upcase}: #{state} source=#{market[:source_date] || 'missing'}"
    market[:tables].each do |table, status|
      puts "  #{table}: rows=#{status[:rows]} stocks=#{status[:stocks]} latest=#{status[:date] || 'missing'}"
    end
  end

  abort "Stock data is incomplete" unless checker.healthy?(report)
end

desc "Refresh only markets with new or incomplete data, then verify and snapshot them"
task daily_refresh: :environment do
  begin
    $stdout.sync = true
    Stock::RefreshRun.new.call do
      Rake::Task[:database_backup].invoke
      progress = lambda do |area, state|
        message = state == :started ? "Checking #{area.upcase} market data..." : "Finished checking #{area.upcase}."
        puts message
      end
      checker = Stock::DataStatus.new(progress: progress)
      report = checker.call
      areas = checker.refresh_areas(report)

      if areas.empty?
        latest = report.values.filter_map { |market| market[:source_date] }.max
        puts "No refresh needed. All markets are healthy through #{latest || 'an unavailable date'}."
      else
        puts "Markets requiring refresh: #{areas.map(&:upcase).join(', ')}"
        Rake::Task[:refresh].reenable
        Rake::Task[:refresh].invoke(*areas)

        verified = checker.call
        abort "Refresh finished but generated data remains incomplete" unless checker.healthy?(verified)
      end

      captured = Stock::AREAS.to_h { |area| [area, Stock::SignalSnapshot.capture!(area)] }
      missing = captured.select { |_area, rows| rows.zero? }.keys
      abort "Snapshot capture produced no rows for: #{missing.map(&:upcase).join(', ')}" if missing.any?

      stored = StockSignalSnapshot.group(:area).count
      puts "Daily refresh complete. Captured rows: #{captured.sort.to_h.inspect}. Stored history rows: #{stored.sort.to_h.inspect}"

      # The adjustment factors and the flagged days are derived from the local
      # price history, which the download has just refreshed, so they are
      # re-derived here. A failure here is not a refresh failure: the market
      # data is current either way, and factors that lag by a day only mean a
      # dividend reads as a loss for a day.
      begin
        Stock::AREAS.each do |area|
          stocks = Stock::CorporateActionRebuilder.measured_stocks(area)
          rebuilt = Stock::CorporateActionRebuilder.new(area: area).call(stocks)
          puts "#{area.upcase}: rebuilt #{rebuilt.events} corporate action(s), #{rebuilt.anomalies.size} flagged day(s)"
        end
      rescue StandardError => error
        puts "WARNING: could not rebuild the price adjustment factors: #{error.message}"
      end

      Stock::AREAS.each do |area|
        report = Stock::SignalNotifier.new(area).call
        next if report.empty?

        if ENV["STAVE_NOTIFY_EMAIL"].present?
          begin
            SignalMailer.daily_digest(report).deliver_now
            puts "Sent #{area.upcase} signal changes to #{ENV['STAVE_NOTIFY_EMAIL']}: #{report.buys.size} buy, #{report.sells.size} sell"
          rescue StandardError => error
            puts "Signal email for #{area.upcase} failed: #{error.message}"
          end
        else
          puts "#{area.upcase} signal changes: #{report.buys.size} buy, #{report.sells.size} sell (set STAVE_NOTIFY_EMAIL to receive these by email)"
        end
      end
    end
  rescue Stock::RefreshRun::AlreadyRunning => error
    abort error.message
  end
end

desc "Record a refresh failure for runs that abort before the Rails stage"
task record_refresh_failure: :environment do
  message = ENV.fetch("STOCK_REFRESH_ERROR", "Refresh aborted before the Rails stage started")
  Stock::RefreshRun.new.record_failure!(message)
  puts "Recorded refresh failure: #{message}"
end

desc "Preview which markets daily_refresh would recalculate without changing data"
task refresh_plan: :environment do
  checker = Stock::DataStatus.new
  report = checker.call
  areas = checker.refresh_areas(report)

  report.each do |area, market|
    state = market[:healthy] ? "healthy" : "needs refresh"
    puts "#{area.upcase}: #{state} source=#{market[:source_date] || 'missing'}"
  end
  puts areas.empty? ? "No database changes are needed." : "Would refresh: #{areas.map(&:upcase).join(', ')}"
end

desc "Report saved daily signal-history coverage"
task snapshot_status: :environment do
  Stock::AREAS.each do |area|
    snapshots = StockSignalSnapshot.where(area: area)
    puts "#{area.upcase}: rows=#{snapshots.count} dates=#{snapshots.distinct.count(:signal_date)} latest=#{snapshots.maximum(:signal_date) || 'missing'}"
  end
end

desc "Print the signal-change digest for a market (or all markets) and email it when STAVE_NOTIFY_EMAIL is set"
task :signal_notify, [:area] => :environment do |_task, args|
  areas = args.area.present? ? [args.area] : Stock::AREAS
  unsupported = areas - Stock::AREAS
  abort "Unsupported market(s): #{unsupported.join(', ')}" unless unsupported.empty?

  areas.each do |area|
    report = Stock::SignalNotifier.new(area).call
    if report.signal_date.nil?
      puts "#{area.upcase}: not enough signal history yet."
      next
    end
    if report.empty?
      puts "#{area.upcase}: no signal changes between #{report.previous_date} and #{report.signal_date}."
      next
    end

    message = SignalMailer.daily_digest(report)
    puts message.text_part.decoded
    if ENV["STAVE_NOTIFY_EMAIL"].present?
      message.deliver_now
      puts "Sent to #{ENV['STAVE_NOTIFY_EMAIL']}."
    else
      puts "STAVE_NOTIFY_EMAIL is not set; printed the digest without sending."
    end
  end
end

desc "Print the LOHAS stave signal for broad-market indexes and ETFs"
task :index_signals, [:area] => :environment do |_task, args|
  default_areas = Stock::IndexSignals::INSTRUMENTS.map { |instrument| instrument[:area] }.uniq
  areas = args.area.present? ? [args.area] : default_areas
  unsupported = areas - Stock::AREAS
  abort "Unsupported market(s): #{unsupported.join(', ')}" unless unsupported.empty?

  puts "=" * 84
  puts "Index & ETF stave signals"
  puts "=" * 84

  areas.each do |area|
    readings = Stock::IndexSignals.new(area).call
    puts "\n#{area.upcase}"
    if readings.empty?
      puts "  No instruments configured."
      next
    end

    puts format("  %-10s %-14s %-11s %10s  %-6s %-6s %-5s %s", "code", "name", "date", "price", "lohas", "years", "family", "trend")
    readings.each do |reading|
      if reading.status != :ok
        puts format("  %-10s %-14s %s", reading.code, reading.name, reading.status.to_s.tr("_", " "))
        next
      end
      puts format("  %-10s %-14s %-11s %10.2f  %-6s %-6s %-5s %s",
        reading.code, reading.name, reading.date, reading.price,
        reading.lohas_signal.presence || "-", reading.year_signal.presence || "-",
        reading.family,
        Stock::Trend.label(Stock::Trend.classify(reading.year)))
    end
  end
  puts
end


desc "Report stocks whose latest coefficient date trails the market date"
task stale_stocks: :environment do
  Stock::AREAS.each do |area|
    market_date = StocksCoefsStav.where(area: area).maximum(:date)
    next unless market_date

    lagging = StocksCoefsStav.where(area: area).where.not(date: market_date).order(:date, :stock)
    total = StocksCoefsStav.where(area: area).count
    puts "#{area.upcase}: #{lagging.count} of #{total} stocks trail #{market_date}"
    lagging.each do |record|
      puts "  #{record.stock} date=#{record.date} lohas_signal=#{record.lohas_signal.inspect} year_signal=#{record.year_signal.inspect}"
    end
  end
end

desc "stock"
task :stock => :environment do
  puts "stock"
  puts "#{Stock::VERSION}"
  puts "#{RUBY_PLATFORM}"
end

desc "Backtest signal performance across multiple horizons and signal types"
task :backtest, [:area] => :environment do |_task, args|
  area = args.area || Stock::SZSTK
  horizons = [5, 20, 60, 120]
  signal_types = [:buy, :sell]

  puts "=" * 60
  puts "Signal backtest for #{area.upcase}"
  puts "=" * 60

  signal_types.each do |signal_type|
    puts "\n## #{signal_type.to_s.upcase} SIGNALS"
    puts "-" * 40

    horizons.each do |horizon|
      report = Stock::SignalPerformance.new(area, horizon: horizon).call(signal_type: signal_type)

      unless report.ready
        puts "  #{horizon}d: Not enough data (#{report.dates} dates, need #{Stock::SignalPerformance::MINIMUM_DATES}+)"
        next
      end

      puts "  #{horizon}d horizon (#{report.dates} trading dates):"

      if report.cohorts.empty?
        puts "    No cohorts met minimum sample size (#{Stock::SignalPerformance::MINIMUM_SAMPLE})"
        next
      end

      report.cohorts.each do |cohort|
        label = "#{cohort.year_signal} + #{cohort.lohas_signal}"
        label += " [#{cohort.trend_group}]" if cohort.trend_group
        excess = cohort.excess_return ? "#{cohort.excess_return}%".rjust(8) : "     n/a"
        pool = cohort.baseline_return ? "#{cohort.baseline_return}%".rjust(8) : "     n/a"
        puts "    #{label.ljust(20)} n=#{cohort.sample_size.to_s.ljust(4)} win=#{cohort.win_rate.to_s.rjust(5)}%  avg_ret=#{cohort.average_return.to_s.rjust(7)}%  avg_dd=#{cohort.average_drawdown.to_s.rjust(7)}%  pool=#{pool}  excess=#{excess}"
      end
    end
  end

  puts "\n" + "=" * 60
  puts "Note: Returns are not annualized. Transaction costs are not deducted."
  puts "      Overlapping holding periods are included in the sample."
  puts "      Entry is the close after the signal date; excess is against the model pool of the same day."
  puts "      Prices are dividend- and split-adjusted, so a holding period across an ex-date is measured as the shareholder saw it."
  puts "      A holding period covering a day whose adjusted move no board would allow is dropped."
end

desc "Simulate following the buy/sell recommendation (equal vs. grid position sizing)"
task :simulate_strategy, [:area, :sizing] => :environment do |_task, args|
  area = args.area || Stock::SZSTK
  modes = args.sizing.present? ? [args.sizing] : %w[equal grid]
  results = modes.to_h do |mode|
    [mode, Stock::StrategySimulation.new(area, sizing: mode.to_sym).call]
  end

  puts "=" * 60
  puts "Strategy simulation for #{area.upcase} (#{results.keys.join(' vs. ')})"
  puts "=" * 60

  results.each do |mode, result|
    print_simulation(mode, result, area, detail: results.size == 1)
  end

  if results.size > 1 && results.values.all?(&:ready)
    equal, grid = results.values
    puts "\n## Sizing comparison"
    puts "-" * 40
    puts format("  %-6s %10s %14s %10s %8s %9s %8s", "sizing", "return", "final_equity", "max_dd", "trades", "win_rate", "avg_cap")
    results.each do |mode, result|
      wins = result.trades.count { |trade| trade.return_pct.positive? }
      avg_committed = result.trades.any? ? result.trades.sum(&:weight) / result.trades.size : 0.0
      puts format("  %-6s %9s%% %14.2f %9s%% %8d %8s%% %8.2f",
        mode, result.total_return, result.final_equity, result.max_drawdown,
        result.trades.size, result.trades.any? ? (wins.fdiv(result.trades.size) * 100).round(2) : "—", avg_committed)
    end
    delta = (grid.total_return - equal.total_return).round(2)
    dd_delta = (grid.max_drawdown - equal.max_drawdown).round(2)
    puts "  grid minus equal: #{delta >= 0 ? '+' : ''}#{delta}pp return, #{dd_delta >= 0 ? '+' : ''}#{dd_delta}pp max drawdown"

    zones = grid.trades.group_by { |trade| trade.weight }.sort_by { |weight, _| weight }
    if zones.any?
      breakdown = zones.map do |weight, trades|
        wins = trades.count { |trade| trade.return_pct.positive? }
        "#{weight}x n=#{trades.size} win=#{(wins.fdiv(trades.size) * 100).round}%"
      end
      puts "  grid entries by depth weight: #{breakdown.join(', ')}"
    end
  end

  puts "\n" + "=" * 60
  puts "Note: grid sizing weights entries #{Stock::StrategySimulation::GRID_WEIGHTS.map { |zone, weight| "#{zone}x zone=#{weight}" }.join(', ')}"
  puts "      (stave zone -3 = below the -2SD line, -2 = between -1SD and -2SD); equal sizing is unweighted."
  puts "      Forced exit after #{Stock::StrategySimulation::MAX_HOLD_DAYS} trading days without a sell signal. Assumes #{(Stock::StrategySimulation::BUY_COST_RATE * 100).round(2)}% commission on buys and"
  puts "      #{(Stock::StrategySimulation::SELL_COST_RATE * 100).round(2)}% commission + stamp duty on sells."
end

desc "Backfill historical signal snapshots for backtesting by replaying LOHAS/YEARS/STAVE against trimmed price history"
task :backfill_signal_history, [:to, :from] => :environment do |_task, args|
  to = (args.to || 63).to_i
  from = (args.from || 1).to_i
  abort "to must be a positive integer" unless to.positive?
  abort "from must be a positive integer no greater than to" unless from.positive? && from <= to

  original_config = ActiveRecord::Base.connection_db_config
  production_database = original_config.database
  abort "No active SQLite database found to back up" unless production_database && File.file?(production_database)

  scratch_dir = Rails.root.join("tmp", "backfill")
  FileUtils.mkdir_p(scratch_dir)
  scratch_path = scratch_dir.join("scratch-#{Time.current.strftime('%Y%m%d-%H%M%S-%L')}.sqlite3")

  puts "Cloning #{production_database} to #{scratch_path}..."
  Stock::DatabaseBackup.new.call(scratch_path)

  begin
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: scratch_path.to_s)

    Stock::AREAS.each do |area|
      (from..to).each do |trim|
        StocksCoefsLoha.where(area: area).delete_all
        StocksCoefsYear.where(area: area).delete_all
        StocksCoefsStav.where(area: area).delete_all

        lohas = Stock::Stock.new(area, Stock::LOHAS, trim: trim)
        lohas.models(StocksCoefsLoha)
        lohas.staves(StocksCoefsLoha)

        years = Stock::Stock.new(area, Stock::YEARS, trim: trim)
        years.models(StocksCoefsYear)
        years.staves(StocksCoefsYear)

        Stock::Stock.new(area, Stock::STAVE).result
        captured = Stock::SignalSnapshot.capture!(area)

        puts "#{area.upcase} trim=#{trim}/#{to}: captured #{captured} row(s)"
      end
    end
  ensure
    ActiveRecord::Base.establish_connection(original_config)
  end

  puts "Merging backfilled snapshots into #{production_database}..."
  connection = ActiveRecord::Base.connection
  connection.execute("ATTACH DATABASE #{connection.quote(scratch_path.to_s)} AS backfill")
  inserted = connection.exec_update(<<~SQL)
    INSERT OR IGNORE INTO stock_signal_snapshots
      (stock, area, signal_date, price, long_trend, year_trend, lohas_signal, year_signal,
       lohas_channel, lohas_stave, year_channel, year_stave, created_at, updated_at)
    SELECT stock, area, signal_date, price, long_trend, year_trend, lohas_signal, year_signal,
           lohas_channel, lohas_stave, year_channel, year_stave, created_at, updated_at
    FROM backfill.stock_signal_snapshots
  SQL
  connection.execute("DETACH DATABASE backfill")
  File.delete(scratch_path)

  puts "Backfill complete. Inserted #{inserted} new signal snapshot row(s)."
end
