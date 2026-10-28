module StocksHelper
  def market_navigation(current_area)
    safe_join(Stock::AREAS.map do |area|
      classes = ["market-tab", ("is-active" if area == current_area)].compact
      link_to(area.upcase, stocks_by_area_path(area), class: classes, aria: { current: ("page" if area == current_area) })
    end)
  end

  # The catalogue and the ranking rules hand back the key of a phrase; the
  # words themselves live in config/locales, so the same signal reads
  # differently depending on which language the reader asked for.
  def signal_badge(code)
    normalized = code.presence
    return content_tag(:span, t("actions.no_signal"), class: "signal-badge signal-neutral") unless normalized

    signal = Stock::SignalCatalog::BY_CODE[normalized]
    tone = signal&.fetch(:tone, nil) || "neutral"
    detail = signal&.fetch(:detail, nil)
    content_tag(:span, class: "signal-badge signal-#{tone}", title: (detail ? t(detail) : normalized)) do
      safe_join([
        content_tag(:span, normalized, class: "signal-code"),
        content_tag(:span, t(signal&.fetch(:badge_action, nil) || :"actions.signal"), class: "signal-action")
      ])
    end
  end

  def linked_signal_badge(code, return_filter: nil)
    label = code.presence || t("actions.no_signal")
    anchor = "signal-#{code.downcase}" if code.present?
    guide_options = { area: @area, anchor: anchor }
    guide_options[:return_signal] = return_filter if return_filter.present? && return_filter != "all"
    link_to(
      signal_badge(code),
      signal_guide_path(**guide_options),
      class: "signal-guide-link",
      aria: { label: t("common.open_signal_guide", label: label) }
    )
  end

  def formatted_number(value)
    value.nil? ? t("common.dash") : number_with_precision(value, precision: 2, strip_insignificant_zeros: true)
  end

  def chart_date_range(series)
    dates = Array(series).flat_map { |item| Array(item[:data]) }.filter_map do |point|
      Date.parse(point.first.to_s) if point.respond_to?(:first) && point.first.present?
    rescue Date::Error
      nil
    end
    return t("common.date_range_unavailable") if dates.empty?

    "#{dates.min.iso8601} – #{dates.max.iso8601}"
  end

  def data_recency(date)
    return { label: t("data_recency.unknown"), tone: "unknown" } unless date

    age = (Date.current - date).to_i
    return { label: t("data_recency.recent"), tone: "recent" } if age <= 3

    { label: t("data_recency.stale"), tone: "stale" }
  end

  def refresh_finished_date(value)
    Time.iso8601(value).in_time_zone("Asia/Shanghai").to_date
  rescue ArgumentError, TypeError
    nil
  end

  def refresh_duration(status)
    started_at = Time.iso8601(status[:started_at])
    finished_at = Time.iso8601(status[:finished_at])
    seconds = [(finished_at - started_at).round, 0].max
    minutes, remaining_seconds = seconds.divmod(60)
    minutes.positive? ? "#{minutes}m #{remaining_seconds}s" : "#{remaining_seconds}s"
  rescue ArgumentError, TypeError
    nil
  end

  # Both of these used to keep their own copy of the slope thresholds and the
  # band labels, so the buy-candidate list on the market page and a stock's own
  # trend health could drift apart. Stock::Trend now owns both.
  def trend_status_label(status)
    t(Stock::Trend.label(status))
  end

  def fundamentals_verdict_label(verdict)
    t("fundamentals.verdict.#{verdict}")
  end

  def fundamentals_badge(record)
    quality = Stock::FundamentalsQuality.new(record).call
    content_tag(
      :span, fundamentals_verdict_label(quality.verdict),
      class: "fundamentals-badge fundamentals-#{quality.verdict}",
      title: fundamentals_tooltip(record, quality)
    )
  end

  def signed_percentage(value)
    return t("common.dash") if value.nil?

    formatted = number_to_percentage(value.abs, precision: 1)
    value.negative? ? "-#{formatted}" : "+#{formatted}"
  end

  def market_cap_label(value)
    return t("common.dash") if value.nil?

    number_to_human(value, units: { thousand: "K", million: "M", billion: "B", trillion: "T" }, format: "%n%u")
  end

  def fundamental_check_label(check)
    name = t("fundamentals.check.#{check.name}")
    return t("fundamentals.no_data", name: name, threshold: check.threshold) if check.value.nil?

    comparison = check.met ? "≥" : "<"
    "#{name}: #{signed_percentage(check.value)} #{comparison} #{check.threshold}%"
  end

  def classify_trend(coef)
    Stock::Trend.classify(coef)
  end

  # The switcher is a link rather than a form: it only has to carry the
  # reader to the same page in the other language, and the language it
  # chooses is remembered for the pages that follow.
  def language_switch_link
    target = I18n.locale.to_s == "zh" ? "en" : "zh"
    label = target == "en" ? t("locale.switch_to_english") : t("locale.switch_to_chinese")
    link_to label, locale_path(target), class: "locale-switch", title: t("locale.label")
  end

  private

  def fundamentals_tooltip(record, quality)
    return t("fundamentals.not_fetched") if record.nil?

    parts = quality.checks.map { |check| fundamental_check_label(check) }
    parts << t("fundamentals.report_period", date: record.report_date) if record.report_date
    parts << t("fundamentals.fetched_on", date: record.fetched_at.to_date) if record.fetched_at
    parts.join(" · ")
  end
end
