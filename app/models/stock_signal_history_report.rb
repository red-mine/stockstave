class StockSignalHistoryReport < ApplicationRecord
  validates :area, :schema_version, :price_basis, :payload, :generated_at, presence: true
  validates :area, uniqueness: true
end
