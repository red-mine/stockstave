class ApplicationController < ActionController::Base
  before_action :set_locale

  private

  # The language is remembered in the session: a reader who switched to
  # Chinese on one page should not have to switch again on the next, and a
  # reader who never switched sees the language the app is written in.
  def set_locale
    requested = session[:locale].to_s
    I18n.locale = if I18n.available_locales.map(&:to_s).include?(requested)
                    requested
                  else
                    I18n.default_locale
                  end
  end
end
