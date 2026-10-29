# The fund checkup (FundData, FundCheck). Local only, like the portfolio:
# the data is fetched by hand with `bin/rails funds:refresh` and the page is
# not part of the public preview.
class FundsController < ApplicationController
  before_action { head :not_found if Rails.env.production? }

  def index
    @data = FundData.load
    @query = params[:q].to_s.strip.first(40)
    @index = params[:index].to_s.presence
    @fund = @data.find(@query) if @query.match?(/\A\d{6}\z/)
    @results = if @index
                 @data.on_index(@index)
               elsif @query.present?
                 @data.search(@query)
               else
                 []
               end
  end
end
