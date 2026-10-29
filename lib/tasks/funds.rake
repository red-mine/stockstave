namespace :funds do
  desc "Fetch the fund list, purchase status and index-fund details for the fund checkup (LIMIT=n for a trial)"
  task refresh: :environment do
    $stdout.sync = true   # progress lines reach a redirected log as they happen
    limit = ENV["LIMIT"]&.to_i
    failed = FundFetcher.new.call(limit: limit)
    puts "Fund data saved to #{FundFetcher.directory}"
    exit 1 if failed.is_a?(Array) && failed.size > 50
  end

  desc "Refresh only the fund list and purchase status (seconds, not an hour)"
  task status: :environment do
    FundFetcher.new.call(details: false)
    puts "Fund list and status saved to #{FundFetcher.directory}"
  end
end
