require "test_helper"

class Stock::CorporateActionFetcherTest < ActiveSupport::TestCase
  # A quote client that answers from a fixed list instead of a server.
  class FakeClient
    RECORDS = [
      { date: Date.new(2026, 1, 6), category: Stock::TdxQuote::CATEGORY_EX_RIGHTS,
        cash: 1.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 0.0 },
      { date: Date.new(2026, 1, 7), category: Stock::TdxQuote::CATEGORY_RESIZE,
        cash: 0.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 2.0 },
      { date: Date.new(2026, 1, 8), category: 2,
        cash: 0.0, bonus: 0.0, rights: 0.0, rights_price: 0.0, resize: 0.0 }
    ].freeze

    def initialize(host, records: RECORDS)
      @host = host
      @records = records
    end

    def connect
      raise "no answer from #{@host}" if @host == "down"

      self
    end

    def ex_rights(_area, _stock)
      @records
    end

    def disconnect
      @records = []
    end
  end

  test "keeps only the records that move a price" do
    fetcher = Stock::CorporateActionFetcher.new(servers: %w[up], client_class: FakeClient)

    result = fetcher.call(%w[sz000001])

    records = result.events.fetch("sz000001")
    assert_equal 2, records.size
    assert_equal [Stock::TdxQuote::CATEGORY_EX_RIGHTS, Stock::TdxQuote::CATEGORY_RESIZE],
                 records.map { |record| record[:category] }
    assert_empty result.failures
  end

  # When no server answers, asking the next stock would try all of them
  # again. The fetch has to end instead.
  test "ends the fetch when no server would answer" do
    fetcher = Stock::CorporateActionFetcher.new(servers: %w[down down], client_class: FakeClient)

    error = assert_raises(Stock::CorporateActionFetcher::NoServerAvailable) do
      fetcher.call(%w[sz000001 sz000002])
    end

    assert_match(/no TongdaXin quote server answered/, error.message)
  end

  test "a stock the deadline passed is reported as unanswered" do
    fetcher = Stock::CorporateActionFetcher.new(servers: %w[up], client_class: FakeClient)

    result = fetcher.call(%w[sz000001 sz000002], deadline: Time.now - 1)

    assert_empty result.events
    assert_equal 2, result.failures.size
    assert(result.failures.values.all? { |reason| reason.include?("ran out of time") })
  end
end
