require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

require_relative "../lib/stock"

module StockApp
  class Application < Rails::Application
    # Use the defaults for the framework version this application runs on.
    config.load_defaults 8.1

    # The application does not transform Active Storage images. Disabling the
    # processor avoids requiring the optional image_processing dependency.
    config.active_storage.variant_processor = :disabled

    # The app reads in English by default and can be switched to Chinese. A
    # language is a file under config/locales, not a branch in the code: the
    # domain returns the key of a phrase and the view layer asks for it.
    config.i18n.available_locales = %i[en zh]
    config.i18n.default_locale = :en

    # Custom directories with classes and modules you want to be autoloadable.
    # config.autoloader = :zeitwerk

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
    # config.autoload_paths << Rails.root.join("extras")

    # config.eager_load_paths += %W(
    #   #{config.root}/lib/stock
    #   #{config.root}/lib/stave
    # )

    # config.autoload_paths += %W(
    #   #{config.root}/lib/stock
    #   #{config.root}/lib/stave
    # )

    # config.add_autoload_paths_to_load_path = true
  end
end
