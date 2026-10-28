require "test_helper"

class StockCandidateRankingTest < ActiveSupport::TestCase
  test "ranks explainable current A-share buy candidates and excludes index codes" do
    strong = create_candidate(
      stock: "sh603087", year_signal: "BUY5", lohas_signal: "BUY5",
      year: 0.04, loha: 0.03, boll1: 1, stav1: 1, boll3: 1, stav3: 1
    )
    create_candidate(stock: "sh600001", year_signal: "SAF1", lohas_signal: "BUY4", year: 0.01, loha: 0.01)
    create_candidate(stock: "sh880016", year_signal: "BUY5", lohas_signal: "BUY5", year: 0.1, loha: 0.1)
    create_candidate(stock: "sh600002", year_signal: "BUY5", lohas_signal: "BUY5", date: Date.new(2026, 7, 30))

    candidates = Stock::CandidateRanking.new(Stock::SHSTK).call

    assert_equal %w[sh603087 sh600001], candidates.map(&:stock)
    assert_equal 88, candidates.first.score
    assert_equal :"candidates.confidence.strong", candidates.first.confidence
    assert_equal strong, candidates.first.record
    assert_includes candidates.first.reasons, :"candidates.reasons.position_supported"
    assert_equal :"candidates.history.first_recorded", candidates.first.history_state
    # The slug beside the key is what the style sheet keys off, so a
    # translation must never be able to change it.
    assert_equal :first_recorded, candidates.first.history_slug
  end

  test "ranks signals in the order the event study supports" do
    %w[BUY4 BUY5 CHP0 SAF1].each_with_index do |signal, index|
      create_candidate(stock: "sz00000#{index}", year_signal: signal, lohas_signal: signal)
    end

    candidates = Stock::CandidateRanking.new(Stock::SZSTK).call

    assert_equal %w[SAF1 CHP0 BUY5 BUY4], candidates.map(&:year_signal)
  end

  test "identifies new and continuing buys from prior recorded snapshots" do
    create_candidate(stock: "sz000001", year_signal: "BUY5", lohas_signal: "BUY5")
    create_candidate(stock: "sz000002", year_signal: "BUY5", lohas_signal: "BUY5")
    create_snapshot(stock: "sz000001", year_signal: "WAT9", lohas_signal: "WAT9")
    create_snapshot(stock: "sz000002", year_signal: "SAF1", lohas_signal: "BUY4")

    candidates = Stock::CandidateRanking.new(Stock::SZSTK).call

    assert_equal :"candidates.history.new_buy_signal",
                 candidates.find { |candidate| candidate.stock == "sz000001" }.history_state
    assert_equal :"candidates.history.still_active",
                 candidates.find { |candidate| candidate.stock == "sz000002" }.history_state
  end

  test "uses each candidate's latest prior observation" do
    create_candidate(stock: "sz000001", year_signal: "BUY5", lohas_signal: "BUY5")
    create_snapshot(stock: "sz000001", year_signal: "WAT9", lohas_signal: "WAT9", date: Date.new(2026, 7, 29))
    create_snapshot(stock: "sz000001", year_signal: "SAF1", lohas_signal: "BUY4", date: Date.new(2026, 7, 30))

    candidate = Stock::CandidateRanking.new(Stock::SZSTK).call.first

    assert_equal :"candidates.history.still_active", candidate.history_state
  end

  test "excludes candidates with negative or flat trend slopes" do
    create_candidate(stock: "sz000001", year_signal: "BUY5", lohas_signal: "BUY5", year: 0.04, loha: 0.03)
    create_candidate(stock: "sz000002", year_signal: "BUY5", lohas_signal: "BUY5", year: -0.01, loha: 0.03)
    create_candidate(stock: "sz000003", year_signal: "BUY5", lohas_signal: "BUY5", year: 0.04, loha: 0.0)

    candidates = Stock::CandidateRanking.new(Stock::SZSTK).call

    assert_equal %w[sz000001], candidates.map(&:stock)
  end

  test "limits the ranked result" do
    3.times { |index| create_candidate(stock: "sz00000#{index}", year_signal: "BUY5", lohas_signal: "BUY5") }

    assert_equal 2, Stock::CandidateRanking.new(Stock::SZSTK).call(limit: 2).size
  end

  private

  def create_candidate(stock:, year_signal:, lohas_signal:, date: Date.new(2026, 7, 31), **attributes)
    StocksCoefsStav.create!({
      stock:, area: stock.first(2), price: 50, date:, year_signal:, lohas_signal:,
      year: 0.01, loha: 0.01, boll1: -1, stav1: -1, boll3: -1, stav3: -1
    }.merge(attributes))
  end

  def create_snapshot(stock:, year_signal:, lohas_signal:, date: Date.new(2026, 7, 30))
    StockSignalSnapshot.create!(
      stock: stock, area: stock.first(2), signal_date: date,
      price: 49, year_signal:, lohas_signal:
    )
  end
end
