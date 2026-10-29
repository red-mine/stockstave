# Signal event study

Reproducible pipeline behind [docs/event_study.md](../../docs/event_study.md).
Python 3 with numpy, pandas, pyarrow, requests and pytdx; outputs go to
`tmp/event_study/` (git-ignored).

```bash
cd research/event_study
VIP=../../vipdoc OUT=../../tmp/event_study

# 1. Replay the engine for every A-share and trading day since 2021 (~2 min, 8 cores)
python replay.py $VIP $OUT

# 2. Prove the replay matches the Ruby engine (stratified by signal code)
python verify.py sample $VIP $OUT/verify
(cd ../.. && bin/rails runner research/event_study/engine_truth.rb \
    tmp/event_study/verify/samples.csv tmp/event_study/verify/truth.jsonl)
python verify.py compare $OUT/verify

# 3. Adjusted closes: TDX raw x factors from TDX ex-rights records (~15 min, resumable)
python fetch_xdxr.py $VIP $OUT

#    Optional cross-check: Sina hfq factors (throttles hard; one slow connection).
#    Writes the same adjusted.parquet, so run it into a different OUT.
python fetch_adjusted.py $VIP $OUT/sina

# 4. Statistics -> $OUT/results.csv
python analyze.py $OUT $VIP

# 5. Trend-filter decomposition (report section 10)
python trend_filter.py $OUT $VIP

# 6. Out-of-sample checks (report section 12): replay from 2012, then
#    reproduce 2021-2026, test the findings on the 2012-2020 holdout and
#    walk forward one year at a time
python replay.py $VIP $OUT/2012 --start 20120101
python fetch_xdxr.py $VIP $OUT/2012 --beg 20111201
python out_of_sample.py $OUT/2012 $VIP --claims five_line_claims.json
```

## Testing another idea

The statistics are not tied to the five-line engine. A new idea needs only a
script that writes `signals.parquet`; prices, returns, baselines, Newey-West
errors, Holm correction, the holdout and the walk-forward are shared.

`signals.parquet` has one row per (stock, date, window) for **every stock-day
the rule could have picked from, signal or not**. Those rows are the baseline:
excess return means "versus the other stocks available that day". Writing
only the rows with a signal turns the baseline into a different population,
which is how the first version of the study went wrong.

| Column | Type | Meaning |
|---|---|---|
| `stock` | str | `sz000001`, `sh600000`, `bj920001` ... |
| `date` | int | `yyyymmdd`; entry is the next trading day's close |
| `window` | str | a name for one variant of the rule |
| `signal` | str | the reading that day, `""` for none |
| `family` | str | optional grouping of signals; without it, five-line codes map through `engine.FAMILY` and any other signal is its own family |

Windows and families are read from the data. Signals may be dated every
trading day or only every k-th one; the overlap correction is scaled to the
spacing. `momentum_signals.py` is a worked example (20-day momentum deciles,
ranked every fifth day), using the adjusted prices built above:

```bash
P=$OUT/2012/adjusted.parquet
python momentum_signals.py $P $OUT/momentum
python analyze.py $OUT/momentum $VIP --prices $P --long TOP --short BOTTOM
python out_of_sample.py $OUT/momentum $VIP --prices $P --long TOP --short BOTTOM \
    --study 20210104-20261013 --holdout 20120101-20201231
```

Decide the claims and the holdout before looking at the holdout: write the
findings into a claims file (see `five_line_claims.json` and the docstring
of `out_of_sample.py`) from the study period alone, then run the holdout
once. `ma_cross_signals.py` with `ma_cross_claims.json` is a second worked
example, written up in [docs/ma_cross.md](../../docs/ma_cross.md); `low_vol_signals.py`
is a third ([docs/low_vol.md](../../docs/low_vol.md)). Judge the idea by the walk-forward net of costs against the market,
not by the study-period tables.

| File | Role |
|---|---|
| `engine.py` | Vectorised replay of `Stock::Stock` (`_model`, `_signal_bands`, `_signal`), with Ruby's `Float#round` and `Array#sum` semantics so cent-rounded bands compare identically |
| `engine_truth.rb` | Runs the real engine on historical days by deriving `trim` from the date |
| `verify.py` | Stratified samples and field-by-field comparison (`signal`, `stav`, `boll`, model validity) |
| `replay.py` | Full-market replay, valid stock-days only |
| `fetch_xdxr.py` | Ex-rights events from the TDX quote servers (pytdx) and the multiplicative adjustment of the engine's own TDX closes |
| `fetch_adjusted.py` | Same adjustment from Sina hfq factors; used to cross-check `fetch_xdxr.py` |
| `analyze.py` | Date-weighted excess returns, Newey-West errors, Holm correction; works on any `signals.parquet` |
| `trend_filter.py` | Separates the trend and the price-level parts of the engine's slope filter |
| `out_of_sample.py` | Study-period tables, holdout test of a claims file, by-year results, yearly walk-forward rule selection net of costs |
| `five_line_claims.json` | The report's findings, as tested in section 12 |
| `momentum_signals.py` | Example signal source for a rule that is not the five-line engine |
| `ma_cross_signals.py`, `ma_cross_claims.json` | Moving-average golden/death crosses and their claims ([docs/ma_cross.md](../../docs/ma_cross.md)) |
| `low_vol_signals.py`, `low_vol_claims.json` | Volatility deciles and their claims ([docs/low_vol.md](../../docs/low_vol.md)) |

The TDX files are append-only, so pinning `--end` (default 2026-10-13) keeps
the replay stable while the nightly refresh keeps adding days.

## Why not a vendor's qfq series

Tencent's forward-adjusted (`qfq`) closes subtract cash dividends instead of
scaling by them (Eastmoney's `fqt=1`, used by the first version of this
study, is unverified here: it was throttling when this was checked). For heavy dividend payers the
early history goes to zero or negative (sh600188 starts at -0.46), and
returns computed from it are meaningless -- 142 of 4,969 Tencent series
dipped below 0.5 yuan. Multiplying the raw closes by hfq factors keeps every
return equal to the shareholder's actual return, ex-dates included.

Pre-2025 Beijing codes are folded into their 92xxxx successors
(`engine.bj_aliases`); both the TDX file and the Sina factors of the new code
carry the full history.

## pytdx replies can arrive out of order

pytdx matches replies to requests purely by order. After a timeout, the late
reply to one request is read as the reply to the next, and every following
stock silently receives its predecessor's events. `fetch_xdxr.py` therefore
asks for each stock twice in a row and keeps the answer only when both
agree, reconnecting on any mismatch. Against Sina's factors (465 stocks) the
two sources then agree on every daily return to within 0.1% for 447 stocks
and 0.6% for 11 more (factor rounding); the remaining 7 are
bankruptcy-reorganisation conversions, whose ex-date or reference price the
two vendors record differently.
