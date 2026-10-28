# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_28_000000) do
  create_table "stock_corporate_actions", force: :cascade do |t|
    t.string "area", null: false
    t.float "bonus", default: 0.0, null: false
    t.float "cash", default: 0.0, null: false
    t.integer "category", null: false
    t.datetime "created_at", null: false
    t.date "ex_date", null: false
    t.float "factor", null: false
    t.datetime "fetched_at", null: false
    t.float "resize", default: 0.0, null: false
    t.float "rights", default: 0.0, null: false
    t.float "rights_price", default: 0.0, null: false
    t.string "stock", null: false
    t.datetime "updated_at", null: false
    t.index ["area", "stock", "ex_date", "category"], name: "index_corporate_actions_on_area_stock_date_category", unique: true
    t.index ["area", "stock"], name: "index_corporate_actions_on_area_and_stock"
  end

  create_table "stock_fundamentals", force: :cascade do |t|
    t.string "area", null: false
    t.datetime "created_at", null: false
    t.datetime "fetched_at", null: false
    t.bigint "market_cap"
    t.string "name"
    t.float "pb"
    t.float "pe"
    t.float "pe_ttm"
    t.float "price"
    t.float "profit_yoy"
    t.date "report_date"
    t.float "revenue_yoy"
    t.float "roe"
    t.string "stock", null: false
    t.datetime "updated_at", null: false
    t.index ["area", "stock"], name: "index_stock_fundamentals_on_area_and_stock", unique: true
  end

  create_table "stock_price_anomalies", force: :cascade do |t|
    t.string "area", null: false
    t.float "change_pct", null: false
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.datetime "detected_at", null: false
    t.float "limit_pct", null: false
    t.string "stock", null: false
    t.datetime "updated_at", null: false
    t.index ["area", "stock", "date"], name: "index_price_anomalies_on_area_stock_date", unique: true
  end

  create_table "stock_signal_history_reports", force: :cascade do |t|
    t.string "area", null: false
    t.datetime "created_at", null: false
    t.datetime "generated_at", null: false
    t.datetime "inputs_updated_at"
    t.text "payload", null: false
    t.string "price_basis", null: false
    t.integer "schema_version", null: false
    t.date "source_date"
    t.datetime "updated_at", null: false
    t.index ["area"], name: "index_stock_signal_history_reports_on_area", unique: true
    t.index ["source_date"], name: "index_stock_signal_history_reports_on_source_date"
  end

  create_table "stock_signal_snapshots", force: :cascade do |t|
    t.string "area", null: false
    t.datetime "created_at", null: false
    t.integer "lohas_channel"
    t.string "lohas_signal"
    t.integer "lohas_stave"
    t.float "long_trend"
    t.float "price"
    t.date "signal_date", null: false
    t.string "stock", null: false
    t.datetime "updated_at", null: false
    t.integer "year_channel"
    t.string "year_signal"
    t.integer "year_stave"
    t.float "year_trend"
    t.index ["area", "signal_date"], name: "index_stock_signal_snapshots_on_area_and_signal_date"
    t.index ["area", "stock", "signal_date"], name: "index_signal_snapshots_on_area_stock_date", unique: true
  end

  create_table "stocks_bolls_lohas", force: :cascade do |t|
    t.string "area"
    t.date "date"
    t.float "price"
    t.string "stock"
    t.string "years"
    t.index ["area", "stock", "years", "date"], name: "index_stocks_bolls_lohas_on_area_and_stock_and_years_and_date", unique: true
  end

  create_table "stocks_bolls_years", force: :cascade do |t|
    t.string "area"
    t.date "date"
    t.float "price"
    t.string "stock"
    t.string "years"
    t.index ["area", "stock", "years", "date"], name: "index_stocks_bolls_years_on_area_and_stock_and_years_and_date", unique: true
  end

  create_table "stocks_coefs_lohas", force: :cascade do |t|
    t.string "area"
    t.integer "boll"
    t.float "coef"
    t.date "date"
    t.boolean "good"
    t.float "inter"
    t.float "price"
    t.integer "stav"
    t.string "stave"
    t.string "stock"
    t.integer "years"
    t.index ["area", "stock"], name: "index_stocks_coefs_lohas_on_area_and_stock", unique: true
  end

  create_table "stocks_coefs_stavs", force: :cascade do |t|
    t.string "area"
    t.integer "boll1"
    t.integer "boll3"
    t.date "date"
    t.boolean "good"
    t.float "loha"
    t.string "lohas_signal"
    t.float "price"
    t.integer "stav1"
    t.integer "stav3"
    t.string "stock"
    t.float "year"
    t.string "year_signal"
    t.index ["area", "price"], name: "index_stocks_coefs_stavs_on_area_and_price"
    t.index ["area", "stock"], name: "index_stocks_coefs_stavs_on_area_and_stock", unique: true
  end

  create_table "stocks_coefs_years", force: :cascade do |t|
    t.string "area"
    t.integer "boll"
    t.float "coef"
    t.date "date"
    t.boolean "good"
    t.float "inter"
    t.float "price"
    t.integer "stav"
    t.string "stave"
    t.string "stock"
    t.integer "years"
    t.index ["area", "stock"], name: "index_stocks_coefs_years_on_area_and_stock", unique: true
  end

  create_table "stocks_stave_lohas", force: :cascade do |t|
    t.string "area"
    t.date "date"
    t.float "price"
    t.string "stock"
    t.string "years"
    t.index ["area", "stock", "years", "date"], name: "index_stocks_stave_lohas_on_area_and_stock_and_years_and_date", unique: true
  end

  create_table "stocks_stave_years", force: :cascade do |t|
    t.string "area"
    t.date "date"
    t.float "price"
    t.string "stock"
    t.string "years"
    t.index ["area", "stock", "years", "date"], name: "index_stocks_stave_years_on_area_and_stock_and_years_and_date", unique: true
  end
end
