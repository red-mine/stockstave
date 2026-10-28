# Switches the language and returns the reader to the page they were on.
#
# The choice is kept in the session rather than in the URL on purpose: the
# market pages are addressed by their market (/sz, /sh, /bj) and the stock
# pages by their code, so there is nowhere natural to put a language prefix.
# A session keeps every existing link working in both languages.
class LocaleController < ApplicationController
  def show
    requested = params[:locale].to_s
    session[:locale] = requested if I18n.available_locales.map(&:to_s).include?(requested)

    redirect_back fallback_location: root_path
  end
end
