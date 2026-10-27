require "test_helper"

class TestEnvironmentTest < ActiveSupport::TestCase
  # The suite used to hold `show_exceptions = false`, which Rails 8 no longer
  # reads as "do not show". An exception raised inside a request was rendered
  # as a 500 page, so the test only ever saw a status code and the cause was
  # lost. These two checks fail loudly if that setting ever drifts again.
  test "requests raise their exceptions instead of rendering them" do
    assert_equal :none, Rails.application.config.action_dispatch.show_exceptions
  end

  test "the exception wrapper refuses to show exceptions in this environment" do
    env = Rack::MockRequest.env_for("/stocks").merge(Rails.application.env_config)
    request = ActionDispatch::Request.new(env)
    wrapper = ActionDispatch::ExceptionWrapper.new(Rails.backtrace_cleaner, RuntimeError.new("boom"))

    assert_not wrapper.show?(request),
      "an exception raised inside a request would be rendered instead of raised"
  end
end
