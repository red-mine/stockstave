class CreateStockSignalHistoryReports < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_signal_history_reports do |t|
      t.string :area, null: false
      t.integer :schema_version, null: false
      t.date :source_date
      t.datetime :inputs_updated_at
      t.string :price_basis, null: false
      t.text :payload, null: false
      t.datetime :generated_at, null: false

      t.timestamps
    end

    add_index :stock_signal_history_reports, :area, unique: true
    add_index :stock_signal_history_reports, :source_date
  end
end
