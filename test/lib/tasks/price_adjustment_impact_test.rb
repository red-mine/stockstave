require "test_helper"
require "rake"

class PriceAdjustmentImpactTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("price_adjustment_impact")
    Rake::Task["price_adjustment_impact"].reenable
    @directory = Dir.mktmpdir("impact-report-test")
  end

  teardown do
    Rake::Task["price_adjustment_impact"].reenable
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  test "writes the file it was given, in the language it was given" do
    path = File.join(@directory, "impact.zh.md")

    output, = capture_io { Rake::Task["price_adjustment_impact"].invoke(path, "zh") }

    assert_match(/Wrote #{Regexp.escape(path)}/, output)
    contents = File.read(path, encoding: "UTF-8")
    assert_includes contents, "持有期"
    refute_includes contents, "holding period"
  end

  test "writes the English report when no language is given" do
    path = File.join(@directory, "impact.md")

    capture_io { Rake::Task["price_adjustment_impact"].invoke(path) }

    contents = File.read(path, encoding: "UTF-8")
    assert_includes contents, "holding period"
    refute_includes contents, "持有期"
  end

  # The report is committed, and the repository keeps its text files on LF.
  # A CRLF line ending reads as trailing whitespace on every single line.
  test "writes the report on LF, not CRLF" do
    path = File.join(@directory, "impact.md")

    capture_io { Rake::Task["price_adjustment_impact"].invoke(path) }

    contents = File.binread(path)
    assert_equal 0, contents.scan("\r\n").size
    assert contents.include?("\n")
  end
end
