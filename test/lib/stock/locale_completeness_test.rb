require "test_helper"

# The two language files are a contract with each other. A key that exists in
# English and not in Chinese is a page that shows a "translation missing"
# banner to exactly the reader who asked for Chinese, and it is invisible
# until somebody switches languages. These tests are what keeps the two
# files from drifting apart.
class StockLocaleCompletenessTest < ActiveSupport::TestCase
  SOURCE_ROOTS = %w[app/views app/helpers app/controllers app/mailers].freeze

  def english
    @english ||= flattened(YAML.load_file(Rails.root.join("config/locales/en.yml")).fetch("en"))
  end

  def chinese
    @chinese ||= flattened(YAML.load_file(Rails.root.join("config/locales/zh.yml")).fetch("zh"))
  end

  test "the two languages carry exactly the same keys" do
    assert_equal english.keys.sort, chinese.keys.sort
  end

  test "the two languages fill the same placeholders" do
    english.each do |key, value|
      next unless value.is_a?(String)
      next unless chinese[key].is_a?(String)

      assert_equal value.scan(/%\{(\w+)\}/).flatten.uniq.sort,
                   chinese[key].scan(/%\{(\w+)\}/).flatten.uniq.sort,
                   "placeholders differ for #{key}"
    end
  end

  test "a translation that carries html is marked so" do
    english.each do |key, value|
      next unless value.is_a?(String)
      # "<code>" in the plain-text digest is a placeholder for the reader to
      # fill in, not markup.
      body = value.gsub("<code>", "")
      next unless body.match?(/<[a-z\/]/i)

      assert key.end_with?("_html"), "#{key} carries html but is not marked as html"
    end
  end

  # The domain hands back the key of a phrase. If that key is missing, the
  # page shows the key itself, so the keys are checked here rather than
  # discovered by a reader.
  test "every key the domain hands back can be translated" do
    keys = []

    Stock::SignalCatalog::ENTRIES.each do |signal|
      keys.concat(signal.slice(:badge_action, :action, :detail, :stave, :channel, :summary).values)
    end
    keys.concat(Stock::Trend::LABELS.values)
    keys.concat(%w[buy sell watch].map { |family| Stock::SignalFamily.label(family) })
    keys.concat(%w[buy sell watch].map { |family| Stock::SignalFamily.explanation(family) })

    keys.each do |key|
      assert english.key?(key.to_s), "#{key} is missing from en.yml"
      assert chinese.key?(key.to_s), "#{key} is missing from zh.yml"
    end
  end

  test "every key a template asks for can be translated" do
    keys = source_keys

    assert keys.any?, "no translation keys were found in the app source"
    keys.each do |key|
      assert english.key?(key), "#{key} is missing from en.yml"
      assert chinese.key?(key), "#{key} is missing from zh.yml"
    end
  end

  # Some keys are built at runtime -- t("fundamentals.verdict.#{verdict}") --
  # so the source scan cannot see them. They are listed here instead.
  test "every key built at runtime can be translated" do
    keys = %w[
      fundamentals.verdict.pass fundamentals.verdict.fail fundamentals.verdict.unknown
      fundamentals.check.roe fundamentals.check.revenue_yoy fundamentals.check.profit_yoy
      candidates.confidence.strong candidates.confidence.moderate candidates.confidence.cautious
      candidates.history.first_recorded candidates.history.still_active candidates.history.new_buy_signal
      candidates.reasons.both_buy_family candidates.reasons.both_trends_rising
      candidates.reasons.position_supported candidates.reasons.same_signal
      candidates.reasons.balanced_trends
      home.signals.filters.all
      home.status.refresh_verified home.status.scheduled_refresh_verified
      home.status.date home.status.duration home.status.recovered
      home.status.running home.status.failed home.status.scheduled_running
      home.status.scheduled_failed home.status.schedule
    ]
    (1..10).each do |number|
      keys << "guide.examples.items.#{number}.title"
      keys << "guide.examples.items.#{number}.text"
    end

    keys.each do |key|
      assert english.key?(key), "#{key} is missing from en.yml"
      assert chinese.key?(key), "#{key} is missing from zh.yml"
    end
  end

  private

  def flattened(node, prefix = [], leaves = {})
    case node
    when Hash
      node.each { |key, value| flattened(value, prefix + [key.to_s], leaves) }
    else
      leaves[prefix.join(".")] = node
    end
    leaves
  end

  def source_keys
    files = SOURCE_ROOTS.flat_map do |root|
      Dir.glob(Rails.root.join(root, "**", "*.{erb,rb}"))
    end

    files.flat_map do |path|
      File.binread(path).force_encoding("UTF-8").scan(/\bt\(\s*["']([a-z0-9_.]+)["']/).flatten
    end.uniq
  end
end
