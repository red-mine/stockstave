module Stock
  class CandidateRanking
    # Ordered by 60-day excess return over the model universe in
    # docs/event_study.md: SAF1 > CHP0 > BUY5 > BUY4 on both horizons.
    # None of the differences survives multiple-testing correction, so the
    # order is the evidence; the spacing is not.
    SIGNAL_POINTS = {
      "SAF1" => 30,
      "CHP0" => 27,
      "BUY5" => 24,
      "BUY4" => 20
    }.freeze
    BUY_SIGNALS = SignalFamily::BUY
    A_SHARE_CODE_PATTERNS = {
      "sz" => %w[sz00____ sz30____],
      "sh" => %w[sh60____ sh68____],
      "bj" => %w[bj43____ bj83____ bj87____ bj88____ bj92____]
    }.freeze

    # The wording lives in the locale file, so a candidate carries the key
    # rather than a sentence. The slug is kept beside it because the style
    # sheet keys off the state, and a style must not depend on where a
    # translation happens to live.
    Candidate = Data.define(:record, :score, :agreement, :reasons, :history_state, :history_slug) do
      delegate :stock, :price, :date, :year_signal, :lohas_signal, :year, :loha, to: :record
    end

    def initialize(area)
      @area = area
    end

    def call(limit: 6)
      market = StocksCoefsStav.where(area: @area)
      market_date = market.maximum(:date)
      return [] unless market_date

      records = market
        .where(date: market_date, year_signal: BUY_SIGNALS, lohas_signal: BUY_SIGNALS)
        .where(a_share_condition, *A_SHARE_CODE_PATTERNS.fetch(@area))
        .where("year > 0 AND loha > 0")

      candidates = records.map { |record| evaluate(record) }
        .sort_by { |candidate| [-candidate.score, candidate.stock] }
        .first(limit)

      previous_by_stock = previous_snapshots(candidates, before: market_date)
      candidates.map { |candidate| add_history_state(candidate, previous_by_stock[candidate.stock]) }
    end

    private

    def a_share_condition
      A_SHARE_CODE_PATTERNS.fetch(@area).map { "stock LIKE ?" }.join(" OR ")
    end

    def evaluate(record)
      score = SIGNAL_POINTS.fetch(record.year_signal) + SIGNAL_POINTS.fetch(record.lohas_signal)
      reasons = [:"candidates.reasons.both_buy_family"]

      positive_trends = [record.year, record.loha].count { |trend| trend.to_f.positive? }
      score += positive_trends * 6
      reasons << :"candidates.reasons.both_trends_rising" if positive_trends == 2

      supported_positions = [record.boll1, record.stav1, record.boll3, record.stav3].count { |position| position.to_i >= 0 }
      score += supported_positions * 4
      reasons << :"candidates.reasons.position_supported" if supported_positions == 4

      if record.year_signal == record.lohas_signal
        score += 6
        reasons << :"candidates.reasons.same_signal"
      end

      if balanced_positive_trends?(record)
        score += 6
        reasons << :"candidates.reasons.balanced_trends"
      end

      score = [score, 100].min
      Candidate.new(record:, score:, agreement: agreement_for(score), reasons: reasons.first(3),
                    history_state: nil, history_slug: nil)
    end

    def add_history_state(candidate, previous)
      slug = if previous.nil?
        :first_recorded
      elsif previous.year_signal.in?(BUY_SIGNALS) && previous.lohas_signal.in?(BUY_SIGNALS)
        :still_active
      else
        :new_buy_signal
      end

      Candidate.new(**candidate.to_h, history_state: :"candidates.history.#{slug}", history_slug: slug)
    end

    def previous_snapshots(candidates, before:)
      stocks = candidates.map(&:stock)
      return {} if stocks.empty?

      StockSignalSnapshot
        .where(area: @area, stock: stocks)
        .where(signal_date: ...before)
        .order(signal_date: :desc)
        .to_a
        .group_by(&:stock)
        .transform_values(&:first)
    end

    def balanced_positive_trends?(record)
      return false unless record.price.to_f.positive? && record.year.to_f.positive? && record.loha.to_f.positive?

      ratio = record.year.to_f / record.loha.to_f
      ratio.between?(0.25, 4.0)
    end

    def agreement_for(score)
      return :"candidates.agreement.high" if score >= 85
      return :"candidates.agreement.medium" if score >= 70

      :"candidates.agreement.low"
    end
  end
end
