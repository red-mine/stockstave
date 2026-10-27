require "pathname"
require "securerandom"
require "sqlite3"

module Stock
  class DatabaseBackup
    STOCK_BACKUP_PATTERN = /\Astock-\d{8}-\d{6}-\d{3}\.sqlite3\z/

    def initialize(connection: ActiveRecord::Base.connection)
      @connection = connection
    end

    def self.prune(directory, keep: 7)
      keep = [keep.to_i, 1].max
      directory = Pathname.new(directory)
      return 0 unless directory.directory?

      backups = directory.children
        .select { |path| path.file? && STOCK_BACKUP_PATTERN.match?(path.basename.to_s) }
        .sort
      stale = backups[0...-keep] || []
      stale.each(&:delete)
      stale.size
    end

    def call(destination)
      destination = Pathname.new(destination)
      raise Errno::EEXIST, destination.to_s if destination.exist?

      temporary = destination.dirname.join(".#{destination.basename}.#{SecureRandom.hex(6)}.tmp")
      destination_database = SQLite3::Database.new(temporary.to_s)
      copy_into(destination_database)

      destination_database.close
      destination_database = nil
      File.link(temporary, destination)
      destination
    ensure
      destination_database&.close
      temporary&.delete if temporary&.exist?
    end

    # Copy this connection's database over a file that already exists, in
    # place. Replacing the file would break a server that holds it open --
    # Windows refuses the rename -- while the backup API writes through the
    # destination's own handle, so a running reader keeps working and sees
    # the new contents once the write commits.
    def mirror_into(destination)
      destination = Pathname.new(destination)
      raise Errno::ENOENT, destination.to_s unless destination.file?

      destination_database = SQLite3::Database.new(destination.to_s)
      copy_into(destination_database)
      destination_database.close
      destination_database = nil
      destination
    ensure
      destination_database&.close
    end

    private
      def copy_into(destination_database)
        backup = SQLite3::Backup.new(destination_database, "main", @connection.raw_connection, "main")
        begin
          status = backup.step(-1)
          unless status == SQLite3::Constants::ErrorCode::DONE
            raise SQLite3::Exception, "SQLite backup did not complete (status #{status})"
          end

          backup.finish
          backup = nil
          integrity = destination_database.get_first_value("PRAGMA integrity_check")
          raise SQLite3::Exception, "SQLite backup failed integrity check: #{integrity}" unless integrity == "ok"
        ensure
          backup&.finish
        end
      end
  end
end
