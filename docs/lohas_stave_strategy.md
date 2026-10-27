# 乐活五线谱 (LOHAS Stave) Strategy

This app implements a technical-analysis method created by Prof. 薛兆亨 (Taiwan),
adapted from Dr. 曾渊沧's "曾氏通道" (Hong Kong). It is **not** a musical staff —
"Stave" here is the literal English translation of 五线谱 (wǔxiànpǔ), the term for
a musical staff, borrowed for its "five lines" visual.

## Core assumptions

1. **Mean reversion** — price deviating from its long-run average tends to correct back.
2. **Normal distribution** — price is assumed to be normally distributed around the trend.

A linear-regression trend line is fit over a window (typically **3.5 years**, half an
economic cycle), then four more lines are drawn at ±1 and ±2 standard deviations from
that trend line, for five lines total.

## The five lines

| Line | Name | Meaning |
|---|---|---|
| Top | 乐观线 (+2SD) | Extremely optimistic zone — ~2.5% chance price is this high |
| Upper-mid | 相对乐观线 (+1SD) | Relatively optimistic zone — ~16% chance price is this high |
| Middle | 趋势线/价值线 (TL) | Long-run average trend price |
| Lower-mid | 相对悲观线 (-1SD) | Relatively pessimistic zone — ~16% chance price is this low |
| Bottom | 悲观线 (-2SD) | Extremely pessimistic zone — ~2.5% chance price is this low |

~95% of observations fall within these five lines.

## Why "乐活" (LOHAS)?

乐活 = "Lifestyles of Health and Sustainability" — the strategy is meant for
long-term, low-maintenance investing (no daily monitoring needed), hence the
"relaxed/healthy lifestyle" branding.

## Strategy rules

- Price breaks below the (relatively) pessimistic line → consider **buying**.
- Price breaks above the (relatively) optimistic line → consider **selling**.
- **Slope of the trend line matters**: positive slope (uptrend) → higher win rate for
  "buy low, sell high"; negative slope (downtrend) → lower win rate, can lose money —
  the strategy is meant to be applied only to confirmed uptrends. (This app's backtest
  finds that the uptrend filter itself cost returns in 2021–2026; see Known
  limitations, item 3.)
- The four bands between the five lines can be treated as grid-trading zones.
- Pair with the **乐活通道 (LOHAS Channel)** — built from past-high average, 20-week MA,
  past-low average — to avoid over-trading in extreme zones during black-swan/fat-tail moves.
- Precondition: only apply to fundamentally sound companies; if fundamentals deteriorate,
  the mean-reversion assumption can break down.

## Mapping to this codebase

| Strategy concept | Code |
|---|---|
| 3.5-year window | `LOHAS = 3 * YEARS + YEARS / 2` ([lib/stock.rb](../lib/stock.rb)) |
| 20-week MA (LOHAS Channel) | `STAVE = 20 * WEEKS` ([lib/stock.rb](../lib/stock.rb)) |
| Trend line (TL/价值线) | `Stock::Stock#trend` ([lib/stock/stock.rb](../lib/stock/stock.rb)) |
| ±1SD / ±2SD lines | `Stock::Stock#stave_band(stock, up/down, 1 or 2)` |
| LOHAS Channel (MA + bands) | `Stock::Stock#aver` / `#boll` |
| Combined stave+channel signal | `Stock::Stock#_price` (private) |
| Per-stock five-line series | `StocksStaveLoha` / `StocksStaveYear` tables |
| Per-stock channel series | `StocksBollsLoha` / `StocksBollsYear` tables |
| Combined LOHAS+Year signal | `StocksCoefsStav` table (`loha`/`year` = slope, `lohas_signal`/`year_signal` = signal code, `boll3`/`stav3`/`boll1`/`stav1` = zone codes) |
| Index/ETF readings | `Stock::IndexSignals` ([lib/stock/index_signals.rb](../lib/stock/index_signals.rb)) — same math over curated TDX index/ETF daily files, computed on demand (no table); the stock pipeline's 100-yuan close-price guard is lifted, every other precondition is identical |

## Signal codes (`_price`) — current status

`_price` combines "position vs. five-line stave" with "position vs. LOHAS channel"
into a single code.

**Historical note:** Earlier versions of this code used sequential `if` assignments
(not `elsif`), which caused several signal codes to be permanently shadowed whenever
two conditions overlapped. These structural bugs have since been fixed:

| Signal | Status | Notes |
|---|---|---|
| `WAT9` vs `CHP0` | **Fixed** | `CHP0` previously duplicated `WAT9`'s condition (`mdn_bot`). Corrected to `mdn_boll` in 2023. See "Resolved: `WAT9` vs `CHP0`" below. |
| `SEL3`/`SEL6`/`SEL7` | **Structurally fixed** | Originally dead code due to overlapping `if`s. Now uses nested `if/elsif/else` with `crossed_stave_top`/`crossed_channel_top` guards. Reachable when price breaks above the upper boundary and falls back. |
| `BUY4`/`WAT8` | **Structurally fixed** | Originally dead code (`BUY4` shadowed by `WAT8`). Now uses a ternary on `falling_averages?` to distinguish the two. |

The remaining concern is **semantic verification** — while these signals are now
technically reachable, no public source confirms whether the `crossed_*` and
`falling_averages` distinctions match 薛兆亨's original decision table. The exact
rules likely reside only in the paid CMoney tool.

`_model` ([lib/stock/stock.rb](../lib/stock/stock.rb), `return {} if coef < 1.0 / STAVE`)
already filters out any stock with a non-positive/near-zero slope before it reaches
`_price`. Web research (see Sources below) confirms this matches 薛兆亨's actual
methodology — the five-line method assumes a stock in a confirmed uptrend, and multiple
independent sources describe negative slope as undermining the whole mean-reversion
premise, with no indication that negative-slope stocks are meant to still generate
distinct signals in this system. **So the upstream filter is correct by design, not a bug.**

### Resolved: `WAT9` vs `CHP0`

This was **not** a slope distinction — it's a LOHAS-channel-recovery distinction. Sourced
directly from 薛兆亨/Tivo168's own case studies (CMoney) and a Smart自学网 explainer,
which both state the rule verbatim and give dated examples (e.g. "2016/1/22 五線譜在
TL-2SD，且樂活通道由跌破下沿回到正常區間" → buy):

> 「若股價跌破樂活五線譜的悲觀區，且股價跌破樂活通道下沿時，先不要買進，等到股價回到
> 樂活通道以後再買進。」

i.e. still below the channel's lower edge → **wait** (don't catch the falling knife);
channel has recovered back into normal range while price is still in the extreme
pessimistic five-line zone → **buy**. Fixed in code:

```ruby
stave = "WAT9" if dn2_bot && mdn_bot   # unchanged: still below channel
stave = "CHP0" if dn2_bot && mdn_boll  # fixed: was mdn_bot (dup of WAT9)
```

**Caveat:** every dated example in the sources describes a *breakout-then-reversion
event* (price broke through the channel edge and has *since* returned to normal range) as
the actual trigger — not merely "currently sitting in the normal range." `_price`
only evaluates the current day's snapshot, with no memory of whether the channel was
recently breached, so this fix is a reasonable static approximation of the real rule, not
a fully faithful implementation of it. A fully faithful version would need to track the
channel's recent state transition over time.

### Unverified semantics: `SEL3`/`SEL6`/`SEL7` and `BUY4`/`WAT8`

The signal-generation code is now structurally sound (no dead branches), but the
semantic distinctions remain unconfirmed against public sources:

- **Sell side (`SEL3`/`SEL6`/`SEL7`):** These trigger when price is in the
  `up1_up2 && mup_boll` zone. `SEL3` and `SEL6` additionally require a recent
  breakout above the stave top or channel top (`crossed_stave_top` / `crossed_channel_top`).
  This follows the symmetric logic of the buy-side channel-recovery rule, yet no
  published source explicitly documents these three sell variants.

- **Buy side (`BUY4`/`WAT8`):** These trigger in the `dn1_dn2 && mup_boll` zone.
  The code chooses `WAT8` when all tracked moving averages (5, 10, 20, 40 period)
  are falling, otherwise `BUY4`. The "falling averages" heuristic is a reasonable
  defensive filter, but its provenance is unclear.

Pending access to the original CMoney decision table or a verified explainer,
these distinctions are best treated as **informed approximations** rather than
confirmed strategy rules.

### Sources

- [樂活五線譜結合樂活通道的實證 (CMoney)](https://cmnews.com.tw/article/xuezhaohengtivo168-b374d808-d8c8-11ef-9bed-da1b84cd5fce) — dated buy/sell case studies showing the channel-recovery trigger
- [ETF投資術：先用樂活五線譜找買點 (Smart自学网)](https://smart.businessweekly.com.tw/Reading/IndepArticle.aspx?id=6001781) — states the "wait for channel recovery" rule verbatim
- [薛兆亨&Tivo168 | 樂活五線譜 x 投資儀表板 (CMoney)](https://www.cmoney.tw/app/expert/tivostaff) — tool overview
- [樂活五線譜-薛兆亨Tivo App (App Store)](https://apps.apple.com/tw/app/%E6%A8%82%E6%B4%BB%E4%BA%94%E7%B7%9A%E8%AD%9C-%E8%96%9B%E5%85%86%E4%BA%A8tivo/id1624433798) — confirms authorship/branding

## Known limitations

Ways the current implementation falls short of the strategy as described, beyond the
signal-code bug above:

1. **Fundamentals screen: implemented as a badge, not a filter.** The strategy
   explicitly requires the underlying company to be fundamentally sound
   ("股票背后的公司必须为良好体质的公司") — mean reversion is assumed to fail otherwise.
   The app now fetches per-stock fundamentals (`fundamentals_refresh`) and judges buy
   candidates against them (`Stock::FundamentalsQuality`): PE(TTM), PB, market cap and
   latest price, plus the newest published report's weighted ROE (annualized by report
   period, since Eastmoney reports cumulative figures), revenue YoY and net-profit YoY.
   Verdicts are `pass` / `fail` / `unknown`, surfaced as a green *Sound* / red *Weak* /
   gray *Unverified* badge on candidate cards and a panel on each stock page.

   What it does **not** do: it does not remove candidates. The statistical method is
   still applied — and every buy signal still listed — for any stock with enough price
   history and a positive regression slope, including ones the screen marks `fail` or
   `unknown`. The thresholds (`FUND_ROE_MIN` default 8, `FUND_REVENUE_YOY_MIN` default 0,
   `FUND_PROFIT_YOY_MIN` disabled) are tunable defaults, not values validated against the
   strategy's own backtests, and nothing is fetched at all until the refresh task runs,
   so a fresh install shows gray everywhere. Funds and ETFs are skipped (their PE/PB are
   meaningless) and Beijing stocks whose codes were switched to 920xxx are matched to
   reports by company name. Read the badge as a prompt to check the company yourself,
   not as the precondition the strategy asks for being satisfied.

2. **No grid-trading execution.** The strategy mentions treating the four bands between
   the five lines as grid-trading zones for capital allocation. The app only simulates
   this: `simulate_strategy` can weight entries by how deep the fill-day zone is
   (below −2SD ×2.0, −1SD..−2SD ×1.5, shallower ×1.0) and compares the result against
   equal sizing, but it is a backtest comparison, not live execution logic. This is
   likely acceptable as scope (decision support vs. auto-trading), but is listed here
   for completeness.

3. **The uptrend precondition has a measured cost.** The rule "apply only to confirmed
   uptrends" is implemented as `coef >= 1.0 / STAVE` (0.01 yuan a day) plus the 100-yuan
   price cap. Over 2021–2026, the stocks that pass it trailed the equal-weighted A-share
   market by about 2.9% per 60 trading days on the 3.5-year window and 1.5% on the
   1-year (250-day) year window, before any signal is applied ([event study](event_study.md),
   sections 1 and 10). On the 3.5-year window the cost comes from the trend itself
   (long-horizon reversal): picking the same number of stocks by log-price slope does
   worse, not better. On the year window more of it comes from the yuan-per-day
   threshold favouring high-priced stocks. Within the stocks that pass, the signal
   codes add little: no family's excess return survives multiple-testing correction,
   and only the year-window buy-minus-sell spread does. Treat the signals as a
   description of where price sits in its band, not as evidence that a buy will beat
   the alternatives.

4. **The app's performance report shares the event study's method and its
   prices.** `Stock::SignalPerformance` enters at the close *after* the signal
   date and judges every cohort against the model pool of the same day — the
   stocks the strategy could have picked then, signal or not — with the excess
   weighted by date, exactly as the study does. Returns are measured on
   dividend- and split-adjusted closes: the app fetches the same TongdaXin
   ex-rights records the study did (`Stock::TdxQuote` speaks the quote-server
   protocol directly, so the nightly refresh needs no Python runtime), stores
   them in `stock_corporate_actions`, and derives the same back-adjustment
   factor the study's `adjust()` derives — the two agree to the last bit on
   every stock that was checked against each other. The app derives the factor
   over each stock's whole listed history while the study starts its series in
   2020, so the two factors differ by a constant per stock; returns are ratios,
   so they are the same. Signals are still derived from the raw close, exactly
   as in the study. Three differences remain:

   - **Model pool.** The app's snapshot records a stock only when it has both a
     3.5-year and a 1-year model, so its pool is the intersection of the two
     horizons; the study used each window's own universe. The app's pool is
     therefore smaller than either study baseline.
   - **Minimum pool size.** A baseline needs at least 20 stocks to mean
     anything, so days with a thinner pool drop out of the excess figure and
     the page falls back to the absolute numbers alone. On the Beijing market,
     where the pool is a handful of stocks, there is usually no baseline to
     show at all.
   - **Anomalous days.** A day whose adjusted move exceeds the board's limit
     (10% on the main board, 20% on ChiNext and the STAR market, 30% on the
     Beijing market, the first five sessions of a new listing excepted) means a
     factor is wrong: the vendor missed an ex-rights record, or dated one
     differently. The study drops the returns whose holding window covers such
     a day, and the cohort report does the same. Only A shares are judged —
     the rule rests on the daily price limit, and the app's pool also holds
     funds and sector indices, which have none. A simulated account cannot
     un-buy a position, so the simulation keeps such a trade and reports how
     many were affected rather than quietly banking a number nobody should
     trust.
