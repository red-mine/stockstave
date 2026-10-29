Rails.application.routes.draw do
  get "/preview-health", to: "stocks#preview_health", as: :preview_health
  get "/signal-guide", to: "stocks#signal_guide", as: :signal_guide
  get "/signal-history", to: "stocks#signal_history", as: :signal_history
  # Private holdings (Portfolio): never mounted in production, which is what
  # the public preview runs.
  unless Rails.env.production?
    get "/portfolio", to: "portfolios#show", as: :portfolio
    patch "/portfolio/settings", to: "portfolios#update_settings", as: :portfolio_settings
    post "/portfolio/holdings", to: "portfolios#create_holding", as: :portfolio_holdings
    patch "/portfolio/holdings/:id", to: "portfolios#update_holding", as: :portfolio_holding
    delete "/portfolio/holdings/:id", to: "portfolios#destroy_holding"
    post "/portfolio/rebalanced", to: "portfolios#record_rebalance", as: :portfolio_rebalanced
  end

  get "/locale/:locale", to: "locale#show", as: :locale,
                         constraints: { locale: /en|zh/ }
  get "/:area", to: "stocks#index",
                as: :stocks_by_area,
                constraints: { area: /sz|sh|bj/ }
  get "/stocks/:stock", to: "stocks#show", as: :stock_analysis

  root  "stocks#index"
end
