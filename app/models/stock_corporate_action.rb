class StockCorporateAction < ApplicationRecord
  validates :stock, :area, :ex_date, :category, :factor, presence: true
end
