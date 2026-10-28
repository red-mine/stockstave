require "test_helper"

class StockSignalFamilyTest < ActiveSupport::TestCase
  test "requires agreement for buys and treats either sell horizon as an alert" do
    assert_equal "buy", Stock::SignalFamily.classify("BUY5", "SAF1")
    assert_equal "sell", Stock::SignalFamily.classify("BUY5", "SEL7")
    assert_equal "watch", Stock::SignalFamily.classify("WAT9", "BUY5")
    assert_equal "watch", Stock::SignalFamily.classify(nil, "BUY5")
  end

  # The family names and the explanations are words for a reader, so the
  # domain hands back the key and the locale file holds the wording.
  test "provides user-facing family labels" do
    assert_equal :"signal_family.buy", Stock::SignalFamily.label("buy")
    assert_equal :"signal_family.sell", Stock::SignalFamily.label("sell")
    assert_equal :"signal_family.watch", Stock::SignalFamily.label("watch")

    assert_equal "Buy agreement", I18n.t(Stock::SignalFamily.label("buy"))
    assert_equal "买入一致", I18n.t(Stock::SignalFamily.label("buy"), locale: :zh)
  end

  test "provides user-facing family explanations" do
    assert_match(/Both recorded horizons/, I18n.t(Stock::SignalFamily.explanation("buy")))
    assert_match(/At least one recorded horizon/, I18n.t(Stock::SignalFamily.explanation("sell")))
    assert_match(/no two-horizon buy agreement/, I18n.t(Stock::SignalFamily.explanation("watch")))
    assert_match(/两个窗口的记录信号都属买入族/,
                 I18n.t(Stock::SignalFamily.explanation("buy"), locale: :zh))
  end
end
