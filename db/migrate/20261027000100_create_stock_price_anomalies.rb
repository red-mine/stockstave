class CreateStockPriceAnomalies < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_price_anomalies do |t|
      t.string :area, null: false
      t.string :stock, null: false
      # The day whose adjusted move no board would allow.
      t.date :date, null: false
      t.float :change_pct, null: false
      # The board limit that was exceeded, so a reader can see how far off it was.
      t.float :limit_pct, null: false
      t.datetime :detected_at, null: false

      t.timestamps
    end

    add_index :stock_price_anomalies, %i[area stock date], unique: true,
              name: "index_price_anomalies_on_area_stock_date"
  end
end
