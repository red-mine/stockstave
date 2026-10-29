# The reader's holdings and rebalancing (see Portfolio). Local only: the
# routes are not mounted in production, and the guard below refuses the
# request even if they ever were, because the public preview runs production
# and these figures are private.
class PortfoliosController < ApplicationController
  before_action :refuse_in_production
  before_action :load_portfolio

  def show
    @today = Date.current
    @rows = @portfolio.rows
    @tracked = @portfolio.tracked_plans(@today)
    @new_money = params[:new_money].to_s.delete(",").strip.presence
    return unless @new_money

    @split = @portfolio.split(@new_money)
  rescue Portfolio::Invalid
    @split = nil
    flash.now[:alert] = t("portfolio.errors.amount")
  end

  def update_settings
    settings = params.require(:settings)
    @portfolio.update_settings(targets: settings.require(:targets).permit(*Portfolio::BUCKETS).to_h,
                               band: settings[:band], interval: settings[:interval])
    redirect_to portfolio_path, notice: t("portfolio.notices.settings_saved")
  rescue Portfolio::Invalid, ActionController::ParameterMissing => e
    redirect_to portfolio_path, alert: error_message(e)
  end

  def create_holding
    @portfolio.add_holding(**holding_params)
    redirect_to portfolio_path, notice: t("portfolio.notices.holding_added")
  rescue Portfolio::Invalid, ActionController::ParameterMissing => e
    redirect_to portfolio_path, alert: error_message(e)
  end

  def update_holding
    @portfolio.update_holding(params[:id].to_s, **holding_params)
    redirect_to portfolio_path, notice: t("portfolio.notices.holding_updated")
  rescue Portfolio::Invalid, ActionController::ParameterMissing => e
    redirect_to portfolio_path, alert: error_message(e)
  end

  def destroy_holding
    @portfolio.remove_holding(params[:id].to_s)
    redirect_to portfolio_path, notice: t("portfolio.notices.holding_removed")
  rescue Portfolio::Invalid => e
    redirect_to portfolio_path, alert: error_message(e)
  end

  def record_rebalance
    @portfolio.record_rebalance
    redirect_to portfolio_path, notice: t("portfolio.notices.rebalanced")
  end

  def create_plan
    p = params.require(:plan)
    @portfolio.add_plan(name: p[:name], fund_code: p[:fund_code], proxy: p[:proxy], amount: p[:amount],
                        day: p[:day], start_on: p[:start_on], months: p[:months])
    # A new ETF has no dividend records yet; fetch them now so the first
    # valuation already counts them. A failure only leaves them uncounted.
    failed = @portfolio.refresh_fund_events
    notice = failed.empty? ? t("portfolio.notices.plan_added") : t("portfolio.notices.plan_added_no_events")
    redirect_to portfolio_path(anchor: "plans-title"), notice: notice
  rescue Portfolio::Invalid, ActionController::ParameterMissing => e
    redirect_to portfolio_path(anchor: "plans-title"), alert: error_message(e)
  end

  def destroy_plan
    @portfolio.remove_plan(params[:id].to_s)
    redirect_to portfolio_path(anchor: "plans-title"), notice: t("portfolio.notices.plan_removed")
  rescue Portfolio::Invalid => e
    redirect_to portfolio_path(anchor: "plans-title"), alert: error_message(e)
  end

  def update_compare_rate
    @portfolio.update_compare_rate(params[:compare_rate])
    redirect_to portfolio_path(anchor: "plans-title"), notice: t("portfolio.notices.settings_saved")
  rescue Portfolio::Invalid => e
    redirect_to portfolio_path(anchor: "plans-title"), alert: error_message(e)
  end

  def refresh_fund_events
    failed = @portfolio.refresh_fund_events
    if failed.empty?
      redirect_to portfolio_path(anchor: "plans-title"), notice: t("portfolio.notices.events_refreshed")
    else
      redirect_to portfolio_path(anchor: "plans-title"), alert: t("portfolio.errors.events", codes: failed.join(", "))
    end
  rescue ::Stock::CorporateActionFetcher::NoServerAvailable
    redirect_to portfolio_path(anchor: "plans-title"), alert: t("portfolio.errors.events", codes: @portfolio.plans.map(&:proxy).uniq.join(", "))
  end

  private

  def refuse_in_production
    head :not_found if Rails.env.production?
  end

  def load_portfolio
    @portfolio = Portfolio.load
  end

  def holding_params
    h = params.require(:holding)
    { name: h[:name], code: h[:code], bucket: h[:bucket], amount: h[:amount],
      institution: h[:institution], matures_on: h[:matures_on] }
  end

  def error_message(error)
    key = error.is_a?(Portfolio::Invalid) ? error.message : "targets"
    t("portfolio.errors.#{key}", default: t("portfolio.errors.generic"))
  end
end
