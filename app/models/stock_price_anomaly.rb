class StockPriceAnomaly < ApplicationRecord
  validates :stock, :area, :date, presence: true
end
