module Stock
  class DataStatus
    COEFFICIENT_TABLES = %w[
      stocks_coefs_lohas
      stocks_coefs_years
      stocks_coefs_stavs
    ].freeze

    SERIES_TABLES = %w[
      stocks_stave_lohas
      stocks_stave_years
      stocks_bolls_lohas
      stocks_bolls_years
    ].freeze

    TABLES = (COEFFICIENT_TABLES + SERIES_TABLES).freeze

    def initialize(connection: ActiveRecord::Base.connection, data_root: ::Stock.data_root, progress: nil)
      @connection = connection
      @data_root = Pathname.new(data_root)
      @progress = progress
    end

    def call(areas = AREAS)
      areas.to_h do |area|
        @progress&.call(area, :started)
        source_date = latest_source_date(area)
        tables = TABLES.to_h { |table| [table, table_status(table, area)] }
        if source_date
          SERIES_TABLES.each do |table|
            tables[table].merge!(stock_set_status(table, area))
          end
        end
        status = { source_date: source_date, tables: tables }
        status[:healthy] = healthy_market?(status)
        @progress&.call(area, :finished)
        [area, status]
      end
    end

    def healthy?(report)
      report.values.all? { |market| market[:healthy] }
    end

    def refresh_areas(report)
      report.filter_map { |area, market| area unless market[:healthy] }
    end

    def healthy_market?(market)
      source_date = market[:source_date]
      return false unless source_date

      coefficients = COEFFICIENT_TABLES.map { |table| market[:tables].fetch(table) }
      return false unless coefficients.all? { |status| status[:rows].positive? && status[:date] == source_date }

      combined_stocks = market[:tables].fetch("stocks_coefs_stavs")[:stocks]
      SERIES_TABLES.all? do |table|
        status = market[:tables].fetch(table)
        expected_series_date = table.include?("loha") ? source_date.beginning_of_quarter : source_date.beginning_of_month
        status[:rows].positive? &&
          status[:stocks] == combined_stocks &&
          status[:missing_stocks].to_i.zero? &&
          status[:extra_stocks].to_i.zero? &&
          status[:date] == expected_series_date
      end
    end

    private

    def latest_source_date(area)
      directory = @data_root.join(area, "lday")
      return nil unless directory.directory?

      directory.children.filter_map do |path|
        next unless path.file? && path.extname.casecmp?(".day") && path.size >= 32

        File.open(path, "rb") do |file|
          file.seek(-32, IO::SEEK_END)
          encoded = file.read(4).unpack1("L<")
          Date.new(encoded / 10_000, encoded / 100 % 100, encoded % 100)
        rescue Date::Error
          nil
        end
      end.max
    end

    # Equal DISTINCT counts do not prove equal coverage: one missing stock and
    # one unexpected stock cancel each other out. Compare the actual sets in
    # SQL so a partial chart refresh cannot look healthy merely by row count.
    def stock_set_status(table, area)
      quoted_area = @connection.quote(area)
      row = @connection.select_one(<<~SQL.squish)
        SELECT
          (SELECT COUNT(*) FROM (
            SELECT stock FROM stocks_coefs_stavs WHERE area = #{quoted_area}
            EXCEPT
            SELECT stock FROM #{table} WHERE area = #{quoted_area}
          )) AS missing_stocks,
          (SELECT COUNT(*) FROM (
            SELECT stock FROM #{table} WHERE area = #{quoted_area}
            EXCEPT
            SELECT stock FROM stocks_coefs_stavs WHERE area = #{quoted_area}
          )) AS extra_stocks
      SQL
      {
        missing_stocks: row.fetch("missing_stocks").to_i,
        extra_stocks: row.fetch("extra_stocks").to_i
      }
    end

    def table_status(table, area)
      quoted_area = @connection.quote(area)
      row = @connection.select_one(<<~SQL.squish)
        SELECT COUNT(*) AS rows,
               COUNT(DISTINCT stock) AS stocks,
               MAX(date) AS date
        FROM #{table}
        WHERE area = #{quoted_area}
      SQL
      {
        rows: row.fetch("rows").to_i,
        stocks: row.fetch("stocks").to_i,
        date: row["date"] && Date.iso8601(row["date"])
      }
    end
  end
end
