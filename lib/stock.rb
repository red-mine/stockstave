require "pathname"

module Stock
  SZSTK = "sz"
  SHSTK = "sh"
  BJSTK = "bj"
  AREAS = [SZSTK, SHSTK, BJSTK].freeze
  WEEKS = 5
  YEARS = 250
  STAVE = 20  * WEEKS
  LOHAS = 3   * YEARS + YEARS / 2
  SMUTH = 2   * WEEKS
  # TongdaXin .day records store prices as integers scaled by 100
  # (cent-yuan). Deliberately its own constant: the decode factor is a
  # data-format detail, not the same thing as the unrelated STAVE
  # moving-average window even though both numerically equal 100 today.
  PRICE_SCALE = 100

  def self.data_root
    default_root = if RUBY_PLATFORM.include?("linux")
      "vipdoc"
    else
      "C:/new_tdx/vipdoc"
    end
    Pathname.new(ENV.fetch("TDX_DATA_PATH", default_root)).expand_path
  end
end

require_relative "stock/version"
require_relative "stock/railtie"
require_relative "stock/database_backup"
require_relative "stock/data_status"
require_relative "stock/refresh_run"
require_relative "stock/refresh_schedule"
require_relative "stock/preview_health"
require_relative "stock/signal_family"
require_relative "stock/signal_catalog"
require_relative "stock/trend"
require_relative "stock/candidate_ranking"
require_relative "stock/signal_snapshot"
require_relative "stock/signal_performance"
require_relative "stock/strategy_simulation"
require_relative "stock/index_benchmark"
require_relative "stock/index_signals"
require_relative "stock/signal_timeline"
require_relative "stock/signal_notifier"
require_relative "stock/fundamentals_fetcher"
require_relative "stock/fundamentals_quality"
require_relative "stock/tdx_quote"
require_relative "stock/day_file"
require_relative "stock/price_adjustment"
require_relative "stock/price_anomalies"
require_relative "stock/corporate_action_fetcher"
require_relative "stock/corporate_action_rebuilder"
require_relative "stock/corporate_action_importer"
require_relative "stock/stave"
require_relative "stock/stock"
