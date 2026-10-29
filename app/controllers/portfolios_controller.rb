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

  private

  def refuse_in_production
    head :not_found if Rails.env.production?
  end

  def load_portfolio
    @portfolio = Portfolio.load
  end

  def holding_params
    h = params.require(:holding)
    { name: h[:name], code: h[:code], bucket: h[:bucket], amount: h[:amount] }
  end

  def error_message(error)
    key = error.is_a?(Portfolio::Invalid) ? error.message : "targets"
    t("portfolio.errors.#{key}", default: t("portfolio.errors.generic"))
  end
end
