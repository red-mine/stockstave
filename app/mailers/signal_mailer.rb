class SignalMailer < ApplicationMailer
  helper_method :stock_url_for

  def daily_digest(report)
    @report = report
    @base_url = ENV["STAVE_HOST"].to_s.sub(%r{/+\z}, "").presence
    @families = %w[buy sell watch].index_with { |family| report.events.select { |event| event.family == family } }

    subject = +t("mailer.subject", area: report.area.upcase)
    if report.signal_date
      subject << " #{t('mailer.subject_detail', date: report.signal_date, buys: report.buys.size, sells: report.sells.size)}"
    end

    mail(
      to: ENV["STAVE_NOTIFY_EMAIL"].presence || "stave@localhost",
      from: ENV["STAVE_SMTP_FROM"].presence || ENV["STAVE_SMTP_USER"].presence || "stave@localhost",
      subject: subject
    )
  end

  private

  def stock_url_for(stock)
    "#{@base_url}/stocks/#{stock}" if @base_url
  end
end
