module Stock
  module SignalCatalog
    # The catalogue holds the structure of each signal -- its code, its tone,
    # where it sits on the stave and in the channel -- and points at the
    # locale file for the words. A catalogue that carried its own English
    # could only ever say one thing; this one says it in whichever language
    # the reader asked for.
    ENTRIES = [
      { code: "SAF1", badge_action: :"actions.buy", action: :"signal_catalog.SAF1.action", tone: "positive", detail: :"signal_catalog.SAF1.detail", stave: :"signal_catalog.SAF1.stave", channel: :"signal_catalog.SAF1.channel", stave_pos: "low", channel_pos: "lower", summary: :"signal_catalog.SAF1.summary" },
      { code: "SOX2", badge_action: :"actions.hold", action: :"signal_catalog.SOX2.action", tone: "strong", detail: :"signal_catalog.SOX2.detail", stave: :"signal_catalog.SOX2.stave", channel: :"signal_catalog.SOX2.channel", stave_pos: "high", channel_pos: "above", summary: :"signal_catalog.SOX2.summary" },
      { code: "SEL3", badge_action: :"actions.sell", action: :"signal_catalog.SEL3.action", tone: "negative", detail: :"signal_catalog.SEL3.detail", stave: :"signal_catalog.SEL3.stave", channel: :"signal_catalog.SEL3.channel", stave_pos: "high", channel_pos: "upper", summary: :"signal_catalog.SEL3.summary" },
      { code: "BUY4", badge_action: :"actions.buy", action: :"signal_catalog.BUY4.action", tone: "positive", detail: :"signal_catalog.BUY4.detail", stave: :"signal_catalog.BUY4.stave", channel: :"signal_catalog.BUY4.channel", stave_pos: "low", channel_pos: "upper", summary: :"signal_catalog.BUY4.summary" },
      { code: "BUY5", badge_action: :"actions.buy", action: :"signal_catalog.BUY5.action", tone: "positive", detail: :"signal_catalog.BUY5.detail", stave: :"signal_catalog.BUY5.stave", channel: :"signal_catalog.BUY5.channel", stave_pos: "upper", channel_pos: "upper", summary: :"signal_catalog.BUY5.summary" },
      { code: "SEL6", badge_action: :"actions.sell", action: :"signal_catalog.SEL6.action", tone: "negative", detail: :"signal_catalog.SEL6.detail", stave: :"signal_catalog.SEL6.stave", channel: :"signal_catalog.SEL6.channel", stave_pos: "high", channel_pos: "upper", summary: :"signal_catalog.SEL6.summary" },
      { code: "SEL7", badge_action: :"actions.sell", action: :"signal_catalog.SEL7.action", tone: "negative", detail: :"signal_catalog.SEL7.detail", stave: :"signal_catalog.SEL7.stave", channel: :"signal_catalog.SEL7.channel", stave_pos: "high", channel_pos: "upper", summary: :"signal_catalog.SEL7.summary" },
      { code: "WAT8", badge_action: :"actions.wait", action: :"signal_catalog.WAT8.action", tone: "neutral", detail: :"signal_catalog.WAT8.detail", stave: :"signal_catalog.WAT8.stave", channel: :"signal_catalog.WAT8.channel", stave_pos: "low", channel_pos: "upper", summary: :"signal_catalog.WAT8.summary" },
      { code: "WAT9", badge_action: :"actions.avoid", action: :"signal_catalog.WAT9.action", tone: "negative", detail: :"signal_catalog.WAT9.detail", stave: :"signal_catalog.WAT9.stave", channel: :"signal_catalog.WAT9.channel", stave_pos: "deep", channel_pos: "below", summary: :"signal_catalog.WAT9.summary" },
      { code: "CHP0", badge_action: :"actions.buy", action: :"signal_catalog.CHP0.action", tone: "positive", detail: :"signal_catalog.CHP0.detail", stave: :"signal_catalog.CHP0.stave", channel: :"signal_catalog.CHP0.channel", stave_pos: "deep", channel_pos: "lower", summary: :"signal_catalog.CHP0.summary" }
    ].map(&:freeze).freeze

    BY_CODE = ENTRIES.index_by { |entry| entry.fetch(:code) }.freeze

    def self.fetch(code)
      BY_CODE.fetch(code)
    end
  end
end
