Rails.application.routes.draw do
  get "/preview-health", to: "stocks#preview_health", as: :preview_health
  get "/signal-guide", to: "stocks#signal_guide", as: :signal_guide
  get "/signal-history", to: "stocks#signal_history", as: :signal_history
  get "/locale/:locale", to: "locale#show", as: :locale,
                         constraints: { locale: /en|zh/ }
  get "/:area", to: "stocks#index",
                as: :stocks_by_area,
                constraints: { area: /sz|sh|bj/ }
  get "/stocks/:stock", to: "stocks#show", as: :stock_analysis

  root  "stocks#index"
end
