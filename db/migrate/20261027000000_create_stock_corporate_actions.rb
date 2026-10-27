class CreateStockCorporateActions < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_corporate_actions do |t|
      t.string :area, null: false
      t.string :stock, null: false
      t.date :ex_date, null: false
      # 1 = 除权除息 (ex-dividend / ex-rights), 11 = 扩缩股 (share split).
      # The other categories the quote servers report do not move a price.
      t.integer :category, null: false
      # The event's terms, per ten shares, as the quote server reports them.
      t.float :cash, null: false, default: 0.0
      t.float :bonus, null: false, default: 0.0
      t.float :rights, null: false, default: 0.0
      t.float :rights_price, null: false, default: 0.0
      t.float :resize, null: false, default: 0.0
      # The cumulative back-adjustment factor in force from this ex-date: the
      # raw close times this factor is the price a shareholder actually saw.
      t.float :factor, null: false
      t.datetime :fetched_at, null: false

      t.timestamps
    end

    add_index :stock_corporate_actions, %i[area stock ex_date category], unique: true,
              name: "index_corporate_actions_on_area_stock_date_category"
    add_index :stock_corporate_actions, %i[area stock], name: "index_corporate_actions_on_area_and_stock"
  end
end
