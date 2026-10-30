require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Allow an explicitly selected temporary tunnel without weakening the default
  # development host checks.
  config.hosts << ENV["PUBLIC_TUNNEL_HOST"] if ENV["PUBLIC_TUNNEL_HOST"].present?

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.cache_classes = false

  # Do not eager load code on boot.
  config.eager_load = false

  # Keep local development diagnostics, but do not expose source paths and
  # exception traces through the managed public preview tunnel.
  config.consider_all_requests_local = ENV["PUBLIC_PREVIEW"].blank?

  # Enable server timing
  config.server_timing = true

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true

    config.cache_store = :memory_store
    config.public_file_server.headers = {
      "Cache-Control" => "public, max-age=#{2.days.to_i}"
    }
  else
    config.action_controller.perform_caching = false

    config.cache_store = :null_store
  end

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  config.action_mailer.perform_caching = false

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Keep normal development diagnostics while allowing the managed public
  # preview to suppress routine request and SQL noise.
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "debug").to_sym

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = config.log_level == :debug

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # The public preview precompiles into public/assets, and Sprockets prefers
  # a precompiled file it finds there over the live sources: every style
  # written after that precompile silently went missing in development.
  # A separate prefix keeps development on the sources.
  config.assets.prefix = "/dev-assets"

  # Let parallel development processes use separate Sprockets caches. Windows
  # cannot atomically replace a cache file while another process has it open.
  if ENV["ASSET_CACHE_PATH"].present?
    config.assets.configure do |environment|
      environment.cache = if ENV["ASSET_CACHE_PATH"] == "memory"
        Sprockets::Cache::MemoryStore.new
      else
        Sprockets::Cache::FileStore.new(
          ENV.fetch("ASSET_CACHE_PATH"),
          config.assets.cache_limit,
          environment.logger
        )
      end
    end
  end

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true
end
