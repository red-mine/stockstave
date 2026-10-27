ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "tmpdir"

# Writes a TongdaXin .day file so a test can exercise the code that reads the
# local price history without touching the real data directory.
module DayFileFixture
  def write_day_file(root, area, stock, rows)
    directory = File.join(root, area, "lday")
    FileUtils.mkdir_p(directory)
    binary = rows.map do |date, close|
      [date.strftime("%Y%m%d").to_i, 0, 0, 0, (close * Stock::PRICE_SCALE).round, 0.0, 0, 0].pack("V4VfV2")
    end.join
    File.binwrite(File.join(directory, "#{stock}.day"), binary)
  end

  def with_data_root(root)
    Stock.stub(:data_root, Pathname.new(root)) { yield }
  end
end

class ActiveSupport::TestCase
  parallelize(workers: :number_of_processors) unless Gem.win_platform?
  include DayFileFixture
end
