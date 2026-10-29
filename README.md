# Stock Stave

**Status: archived research project (October 2026).** The question it was
built to answer has an answer, and no further strategy or feature work is
planned. The code still runs; [Running the code](#running-the-code) explains
how.

## The question

Does the LOHAS Five-Line Stave (乐活五线谱) pick better Chinese A shares?
The method fits a linear trend to each stock's last 3.5 years (875 trading
days, "lohas") and last year (250 days, "year"), draws bands at one and two
standard deviations around it, and adds a 20-week price channel. Where today's
close sits among those bands gives a buy, sell, soar or wait signal. Only
stocks in a confirmed uptrend get a model at all. The strategy and its signal
codes are documented in [docs/lohas_stave_strategy.md](docs/lohas_stave_strategy.md).

## Answer

**No.** The signals do not predict returns well enough to trade, and no way of
using them could have been chosen in advance and made money after costs.

## How it was tested

The project is a Rails application that computes every signal for every
Shanghai, Shenzhen and Beijing A share from TongdaXin daily files, and a
Python research pipeline (`research/event_study/`) that replays the same
engine across the whole market:

- The replay matches the Ruby engine field by field on 914 of 914 stratified
  samples.
- Returns use dividend- and split-adjusted closes, and entry is the close
  *after* the signal, so no trade uses the price that produced it.
- Excess return is measured against the stocks the strategy could have picked
  that day, with Newey-West errors for overlapping holding periods and Holm
  correction for multiple tests.
- The study was written on 2021-2026. The price files reach back to listing
  and keep delisted stocks, so 2012-2020 became a holdout the study never saw,
  free of survivorship bias.

## What it found

| Finding | 2021-2026 (study) | 2012-2020 (holdout) |
|---|---|---|
| Year-window buy minus sell, 10 days | +0.65% (t 3.3) | -0.09% (t -0.6) |
| Year-window sell signal vs pool, 20 days | -1.21% (t -2.8) | +0.13% (t 0.5) |
| Lohas uptrend pool (no signal) vs whole market, 60 days | -2.92% (t -3.2) | -1.14% (t -1.5) |
| Lohas BUY4 vs pool, 20 days | -1.40% (t -2.9) | -1.04% (t -2.4) |

- The two effects that survived correction in the study period are zero in
  the holdout. Year by year, the buy-sell spread is positive in 9 of 15 years,
  mostly by little, and the sell-signal stocks significantly beat the pool in
  2012, 2013 and 2020; the study's result came from 2022 and 2024.
- Walking forward one year at a time, picking the best long-only rule net of
  costs on the years before and holding it through the next, beat the market
  in 3 of 14 years and averaged -1.62% per 20 trading days.
- What held in both periods is advice about what not to do: the uptrend
  filter does not help (it lags the market in both, significantly only in the
  study period), and BUY4 is not a buy point.

## Why it does not work

1. **The signals use only past closes, the cheapest information in the
   market.** Everyone can draw the same lines; within the stocks the strategy
   can pick, where a price sits among the bands says almost nothing about what
   comes next.
2. **It bets on reversion to the trend, and A shares do not reliably
   revert.** In the falling markets of 2022 and 2024 broken stocks kept
   falling, so the sell signal "worked"; in 2012, 2013 and 2020 the opposite
   held. Which regime is coming is not known in advance.
3. **The uptrend precondition is itself a handicap.** The stocks that rose
   most over 3.5 years tend to lag afterwards, and a slope bar measured in
   yuan per day leans towards high-priced stocks, which lagged in these years.
4. **What effect there was is small and needs a short sale.** The spread
   requires shorting the sell-signal stocks, which A-share retail investors
   effectively cannot do; the long side alone is not significant after the
   0.11% round-trip cost.

The laddered entry and grid execution of the original method were not
tested, but they sit on the same signals and cannot add a prediction the
signals lack.

## What is left to use

- A credible negative answer, reached without trading real money on it.
- A pipeline that turns any A-share stock-selection idea into a full-market,
  out-of-sample test in a day or two: TongdaXin data, ex-rights adjustment,
  vectorised replay, event study and walk-forward
  ([research/event_study/](research/event_study/README.md)).
- The web app, which still draws the stave and channel charts per stock.

## Documents

| Document | Contents |
|---|---|
| [docs/conclusion.md](docs/conclusion.md) | The verdict and the reasons, in one page (Chinese) |
| [docs/event_study.md](docs/event_study.md) | The full study: method, tables, by-year results, holdout and walk-forward (section 12) (Chinese) |
| [docs/ma_cross.md](docs/ma_cross.md) | Moving-average golden crosses, tested with the same pipeline: they underperform (Chinese) |
| [docs/low_vol.md](docs/low_vol.md) | Low-volatility stock selection: no edge for calm stocks, but the most volatile decile lags in both periods (Chinese) |
| [docs/lohas_stave_strategy.md](docs/lohas_stave_strategy.md) | The strategy, signal definitions and known limitations |
| [docs/price_adjustment_impact.md](docs/price_adjustment_impact.md) | What switching to adjusted prices changed in the app's reports |
| [research/event_study/README.md](research/event_study/README.md) | How to reproduce every number |

## Running the code

Stock Stave is a Ruby on Rails application. It computes the regression trend
bands, the 20-week channel and the combined buy/sell/wait classification for
every stock, refreshes them nightly from the official TongdaXin archive, and
serves the charts. The signals it shows are the ones tested above: read them
as a description of where a price sits, not as a recommendation.

### Requirements

- Ruby 3.4.10
- Bundler 2.5.3
- RubyInstaller's MSYS2 development kit on Windows
- SQLite 3 (provided by the bundled Windows gem)
- TongdaXin daily price files for real stock calculations

On Windows, install the `Ruby+Devkit 3.4.10-1 (x64)` RubyInstaller package. If
native gems fail because `yaml.h` is missing, run this from an administrator
PowerShell:

```powershell
C:\Ruby34-x64\bin\ridk.cmd exec pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-libyaml
```

### Setup

From PowerShell in the repository directory:

```powershell
gem install bundler -v 2.5.3
bundle install
bundle exec rails db:migrate
```

> **Security note:** `config/master.key` is git-ignored and is not in this
> repository — only the encrypted `config/credentials.yml.enc` is tracked, and it
> cannot be read without the key. Keep the key out of version control, and generate
> a fresh one (`bin/rails credentials:edit`) before deploying to production.

The environments use separate databases:

- Development and production: `db/stock.sqlite3`
- Test: `db/test.sqlite3`

### Price data

Set `TDX_DATA_PATH` to the TongdaXin `vipdoc` directory. For example, in
PowerShell:

```powershell
$env:TDX_DATA_PATH = "C:\new_tdx\vipdoc"
```

When the variable is not set, the calculation engine uses:

- Windows: `C:/new_tdx/vipdoc/<area>/lday/`
- Linux: `vipdoc/<area>/lday/`

`<area>` is `sz`, `sh`, or `bj`. Each stock needs enough history for the chosen
window plus the 20-week channel.

### Adjusted prices

Signals are derived from the raw TongdaXin close, and they always were. The
*returns* the app reports are measured on dividend- and split-adjusted closes,
so a holding period across an ex-dividend date is judged the way a shareholder
would have experienced it. This is the same adjustment the event study uses
(`research/event_study/fetch_xdxr.py`), and the two implementations produce
identical numbers.

The ex-rights records come from the TongdaXin quote servers, fetched over the
binary quote protocol by `Stock::TdxQuote` — no Python runtime is involved.
The local TongdaXin install holds only `.day` files, so the records have to be
fetched over the network:

```powershell
bundle exec rails corporate_actions_refresh      # all markets
bundle exec rails "corporate_actions_refresh[sz]"
```

The task stores one row per price-moving event under `stock_corporate_actions`
(an ex-dividend/ex-rights event or a share split — the other categories the
servers report do not move a price) together with the back-adjustment factor
the event leaves behind. It then checks each A share's adjusted series for a
daily move no board would allow: 10% on the main board, 20% on ChiNext and the
STAR market, 30% on the Beijing market, the first five sessions of a new
listing excepted. Such a day means a factor is wrong — the vendor missed an
ex-rights record, or dated one differently — and it is recorded under
`stock_price_anomalies`. Only A shares are judged, because the rule rests on
the daily price limit and a fund or a sector index has none. The cohort
report drops the holding periods that cover a flagged day; the simulated
account keeps the trade but reports how many of its trades were affected,
because an account cannot un-buy a position.

The factors depend on the local price history and on the records the quote
servers hold, so the nightly refresh fetches the records again and re-derives
them. The fetch is given a time budget, so a quote server that stops
answering cannot hold the refresh open; when no server answers, the factors
are rebuilt from the records already stored instead. Both steps can also be
run by hand:

```powershell
bundle exec rails corporate_actions_refresh      # fetch and store
bundle exec rails corporate_actions_rebuild      # re-derive from what is stored
bundle exec rails corporate_actions_status
```

`corporate_actions_status` reports how many events each market has, how many
of them actually move a price, and how many days are flagged. The report page
states which price basis it used, so a number measured on raw prices is never
read as one measured on adjusted prices.

To see what the adjustment changed, the same report can be measured on both
price bases and set side by side:

```powershell
bundle exec rails price_adjustment_impact_reports
```

Both sides come from the same code and differ only in the price basis. The
report is kept in two languages, because the research notes it answers to are
Chinese while the code and the rest of the docs are English:

- `docs/price_adjustment_impact.md` — English
- `docs/price_adjustment_impact.zh.md` — 中文

Both files come out of one computation, so they cannot disagree about a
number. To write a single file instead:

```powershell
bundle exec rails "price_adjustment_impact[docs/price_adjustment_impact.md]"
bundle exec rails "price_adjustment_impact[docs/price_adjustment_impact.zh.md,zh]"
```

### Generate analysis data

For normal daily operation, run:

```powershell
$env:Path = "C:\Ruby34-x64\bin;$env:Path"
bundle exec rails daily_refresh
```

The Rails task recalculates from the files already present under
`TDX_DATA_PATH`. On Windows, the scheduled runner performs the complete flow:

```powershell
pwsh -File bin\daily-refresh.ps1
```

It checks the official TongdaXin `hsjday.zip` date, skips the download when all
three local markets are current, and otherwise downloads to `tmp/tdx-update`,
rejects unsafe archive paths, verifies the final record date for SZ, SH, and BJ,
and incrementally synchronizes the validated files before Rails recalculates.
Use `-SkipTdxUpdate` only for offline diagnostics, or `-TdxDataPath PATH` to
override the source directory for both the downloader and Rails.

This checks all three markets first, skips healthy markets, creates a SQLite
backup before recalculation, refreshes only new or incomplete markets, saves a
daily signal snapshot, and verifies the generated data before succeeding. The
signal snapshot is recorded after every run, including runs that skip
recalculation. Run `bundle exec rails snapshot_status` to inspect accumulated
signal history. After the corporate actions are refreshed, each run also
precomputes the web signal-history performance and simulation reports; run
`bundle exec rails signal_history_reports` to rebuild those reports without a
full refresh. Use `bundle exec rails refresh_plan` first when you only want to
preview which markets need work. Daily refreshes are locked so two copies cannot
modify the database concurrently, and the front page reports the last run as
running, successful, or failed. A run fails if any healthy market produces no
snapshot rows, and its log reports newly captured rows separately from total
stored history. Every daily run creates and integrity-checks a retained SQLite
backup before either recalculation or signal-history writes, including nights
when market coefficients are already current.

#### Schedule the Windows refresh

Install a daily Windows task (20:30 local time by default) from PowerShell:

```powershell
pwsh -File bin\install-daily-refresh-task.ps1
```

The task downloads and validates the latest official TongdaXin day archive,
refreshes the tracked database, and then mirrors that database over the
isolated UI database at `tmp/ui-stock.sqlite3` that the public preview
serves — nothing else writes that file, so without the mirror the public
site would keep serving whatever the preview database held when it was
seeded. The task uses the Ruby 3.4 executable explicitly, starts missed runs
when the computer becomes
available, and refuses overlapping executions. Its latest output is saved to
`log/daily-refresh/latest.log`. Timestamped logs are retained for the latest 30
runs so failures can be audited later. Every run identifies its source in
`tmp/stock-refresh-status.json`; the task also preserves the most recent scheduled
run in `tmp/stock-refresh-scheduled-status.json`, allowing the website to distinguish
scheduler evidence from a manual refresh. If Windows terminates a run at its four-hour
limit, the next run safely recovers the empty lock after five hours and reports
that recovery on the website. Choose a different time with `-At HH:mm`.

#### Schedule the Linux refresh

Run `bin/daily-refresh.sh` directly for a manual refresh, or install the
systemd user timers. The refresh runs daily at 20:30 local time and retention
cleanup runs weekly:

```sh
bin/install-daily-refresh-timer.sh
```

Before recalculating, the runner checks and safely synchronizes the official
TongdaXin archive using `bin/update-tdx-data.sh`. Pass `--skip-tdx-update` only
for offline diagnostics, or `--tdx-data-path PATH` to override the default
`vipdoc` directory. The updater requires `curl`, `unzip`, `python3`, `rsync`,
and `od`.

The runner resolves `ruby` from `PATH`, falling back to `~/.rbenv/shims/ruby`
(override either with `RUBY_BIN`). It defaults to the tracked `db/stock.sqlite3`
database (override with `--database`), writes the same `log/daily-refresh/latest.log`
and timestamped archives (kept to the latest 30 with `--log-retention`), and marks
each run's source in `tmp/stock-refresh-status.json` via `STOCK_REFRESH_SOURCE`,
matching the Windows task's status contract. The installer enables persistent
systemd user timers and records the installed refresh schedule in
`tmp/stock-refresh-schedule.json` for the website to report. Inspect them with
`systemctl --user list-timers stave-daily-refresh.timer stave-retention.timer`
and view refresh logs with
`journalctl --user -u stave-daily-refresh.service`.

The whole run is serialized with `flock` on `tmp/daily-refresh.lock`, covering the
TongdaXin download as well as the recalculation. Two copies of the runner used to
share `tmp/tdx-update/hsjday.zip.part` and corrupt each other's archive, so a
manual run that starts while the timer is running now skips with
`Another Stock Stave refresh already holds the lock` instead of racing it. Keep a
single scheduler for this reason: installing the timer removes a leftover
`daily-refresh.sh` cron entry left by the deprecated installer. Set
`STOCK_REFRESH_LOCK` to use a different lock file.

A failure that happens before Rails ever boots — a TongdaXin download error, for
instance — is still written to the status files by the `record_refresh_failure`
task, so a broken download makes the front page report
`Last scheduled refresh failed` instead of leaving an older success on screen
while the data ages. The status records the runner's own start time in
`started_at`, so the reported duration covers the failed download too.

`bin/install-daily-refresh-cron.sh` remains available as a deprecated fallback
for Linux systems without systemd user services.

#### Signal email notifications

Every `daily_refresh` run diffs the two newest signal snapshot dates and
reports stocks whose signal family changed — newly entering the buy zone,
new sell alerts, or dropping back to watch. When no recipient is configured
the digest is printed to the refresh log instead, so the run stays useful
offline.

Email is opt-in via the environment; nothing is sent unless
`STAVE_NOTIFY_EMAIL` is set, and a delivery failure is logged without
failing the refresh:

```powershell
$env:STAVE_NOTIFY_EMAIL  = "you@example.com"   # recipient; enables sending
$env:STAVE_SMTP_ADDRESS  = "smtp.qq.com"       # e.g. QQ Mail
$env:STAVE_SMTP_PORT     = "587"               # optional, default 587
$env:STAVE_SMTP_USER     = "you@qq.com"
$env:STAVE_SMTP_PASSWORD = "<mailbox auth code>"
$env:STAVE_HOST          = "http://localhost:3000"  # optional; makes stock links in the email clickable
```

`STAVE_SMTP_FROM` overrides the sender (it defaults to `STAVE_SMTP_USER`),
and `STAVE_SMTP_AUTH` / `STAVE_SMTP_STARTTLS` override the default `plain`
authentication and TLS. For QQ Mail generate an authorization code in the
mailbox settings instead of using the account password.

Preview the digest for one market or all markets without waiting for the
scheduled run:

```powershell
bundle exec rails signal_notify      # prints the digest, sends when configured
bundle exec rails "signal_notify[sz]"
```

#### Fundamentals screening

The strategy's stated precondition is a fundamentally sound company, so the
app can fetch per-stock fundamentals from Eastmoney's public HTTP endpoints
and screen buy candidates against them:

```powershell
bundle exec rails fundamentals_refresh      # all markets
bundle exec rails "fundamentals_refresh[sz]"
```

The refresh upserts one row per stock under `stock_fundamentals`: name, PE
(TTM), PB, total market cap and latest price from the batch quote endpoint
(Tencent `qt.gtimg.cn`, whose TLS survives where Eastmoney's push2 endpoint
drops Ruby connections), plus the newest published report's weighted ROE,
revenue YoY and net-profit YoY from the DataCenter performance report. Funds
and ETFs in the stock universe are skipped — their PE/PB fields mean nothing.
Beijing Exchange stocks whose codes were switched to 920xxx keep their report
matched by company name. Weekly refreshes are enough — reports only change
quarterly. Nothing is sent when you never run the task; candidate cards
simply show no badge.

The quality screen is configured through thresholds (percent values; set an
empty string to disable a check):

```powershell
$env:FUND_ROE_MIN         = "8"   # annualized weighted ROE, default 8
$env:FUND_REVENUE_YOY_MIN = "0"   # revenue YoY, default 0
$env:FUND_PROFIT_YOY_MIN  = ""    # net-profit YoY, disabled by default
```

ROE is annualized by report quarter (Q1 ×4, half-year ×2, Q3 ×4/3) so
mid-year reports are not punished against year-ends. Each buy candidate gets
a fundamentals badge — green "Sound", red "Weak", gray "Unverified" (no data
or an unjudgeable check) — and every stock page has a fundamentals panel
with the raw numbers. This is a data screen, not financial advice.

Refresh all three markets with one command:

```powershell
bundle exec rails refresh
```

The task validates every source directory before changing data, saves a
timestamped database backup under `tmp/backups` (keeping the newest 7 by
default, overridable with `STOCK_BACKUP_KEEP`), and safely resumes stocks that
already have the latest source date. To refresh selected markets only:

```powershell
bundle exec rails "refresh[sz,sh]"
```

Backups named `stock-YYYYMMDD-HHMMSS-LLL.sqlite3` are the automated ones, and the
newest `STOCK_BACKUP_KEEP` of them survive each refresh. A backup made by hand for
a specific change — `stock-pre-fundamentals-migration-...` — matches no pattern, so
pruning deliberately leaves it alone: a scheduled job should not decide when a
safety net a person kept on purpose has become unnecessary. Delete those yourself
once the change has proven out.

Verify source freshness, imported dates, row counts, and chart coverage:

```powershell
bundle exec rails data_status
```

The status task exits unsuccessfully when any market stage is missing or stale,
so it can also be used by scheduled jobs and CI.

List stocks whose latest coefficient date trails the market date (suspended,
delisted, or missing source files):

```powershell
bundle exec rails stale_stocks
```

The individual stages remain available for diagnostics:

```powershell
bundle exec rails "lohas[sz]"
bundle exec rails "years[sz]"
bundle exec rails "stave[sz]"
```

Repeat with `sh` or `bj` as required.

### Read broad-market indexes and ETFs with the same stave

The five-line method is documented for ETFs as much as for stocks, and the
TongdaXin daily files already carry the index and ETF daily bars, so a curated
set of benchmarks can be read on demand — no extra data source and no database
table:

```powershell
bundle exec rails index_signals          # SH + SZ instruments, side by side
bundle exec rails "index_signals[sh]"    # one market
```

The same LOHAS (3.5y) and YEARS (1y) regression plus the same combined
signal codes apply; the difference from the stock pipeline is only that the
stock data guard (which silently skips anything closing above 100 yuan, a
sanity cap for stock prices that every index point level violates) is lifted.
Every other precondition is unchanged: an instrument whose trend slope fails
the strategy's bar reports `no model` instead of producing a signal, exactly
like a downtrending stock. Note the slope bar is an absolute yuan-per-day
threshold, so it is near-automatic for four-digit indexes and genuinely hard
for low-priced ETFs — that quirk is the strategy's own, applied consistently.

### Simulate the strategy on the saved signal history

Once 20 or more trading dates of snapshots are recorded (see
`backfill_signal_history` to rebuild history from existing price data), the
simulation task replays the buy/sell recommendations on every historical day:

```powershell
bundle exec rails simulate_strategy          # equal vs. grid sizing, side by side
bundle exec rails "simulate_strategy[sz]"    # both modes for one market
bundle exec rails "simulate_strategy[sz,grid]"  # one mode, with the daily equity curve
```

Buys are filled at the close *after* the signal — the signal is derived from
the close that produced it — with at most 10 concurrent positions and a forced
exit after 20 trading days without a sell signal. Transaction costs (0.03%
commission on buys; 0.03% commission + 0.05% stamp duty on sells) are deducted,
and the result is compared against the market's buy & hold index.

Grid sizing is the strategy's own idea of the four bands as laddered entry
zones: entries deeper in the pessimistic zone carry a bigger position —

| Fill-day stave zone | Weight |
|---|---|
| −3, below the −2SD line | 2.0× |
| −2, between −1SD and −2SD | 1.5× |
| anything shallower | 1.0× (equal sizing) |

The default run prints both modes plus a comparison (return, drawdown, win
rate, and the grid entries broken down by depth weight) so the sizing choice is
made on data, not vibes. The web app's signal-history page keeps showing the
equal-weight account simulation.

### Run the web application

```powershell
bundle exec rails server
```

Open <http://localhost:3000/sz>, `/sh`, or `/bj`. Select a stock to view its
one-year and 3.5-year stave and channel charts.

#### Read the app in English or Chinese

The app reads in English by default and can be switched to Chinese from the
link above the page. The choice is remembered for the pages that follow, so
a reader only has to switch once.

A language is a file, not a branch in the code:

- `config/locales/en.yml` — the source of truth for every user-facing string
- `config/locales/zh.yml` — the same keys, in Chinese

The two files must carry exactly the same keys, and
`test/lib/stock/locale_completeness_test.rb` fails when they do not. The
terminology follows `docs/event_study.md`, which is the research side of this
app and already writes about these signals in Chinese.

The domain code under `lib/stock` never speaks for itself: the signal
catalogue, the trend bands and the candidate ranking return the key of a
phrase, and the view layer asks for it. Adding a language means adding a
locale file, not editing the engine.

To replace the local server and temporary Cloudflare Quick Tunnel with one
verified command, run:

```powershell
pwsh -File bin\start-public-preview.ps1
```

The command stops only verified Stock Stave Rails and Cloudflare processes,
uses `tmp/ui-stock.sqlite3`, checks both local and public HTTP responses, and
writes the current URL, port, and process IDs to `tmp/public-preview.json`. The
preview database is kept current by the refresh runner, which mirrors the
tracked database over it after every successful run
(`rails mirror_preview_database` does the same thing by hand). Status
checks and recovery reuse that recorded port. Quick
Tunnel URLs are temporary and may change when this command is run again. The
startup is atomically locked, so a scheduled recovery cannot race a manual
publish restart. It retries all-market tunnel readiness for up to 90 seconds and
cleans up newly started processes if any startup gate ultimately fails. The
preview runs Rails in production, so it precompiles its asset bundle first —
only when the fingerprinted files are missing or older than their sources — and
serves them with `RAILS_SERVE_STATIC_FILES`. Production also leaves no
development surface to protect: the `/rails/info` routes are not mounted at all,
`web-console` is not loaded, and error detail is not shown to any requester, so
exposure no longer hinges on the tunnel's `X-Forwarded-For` header.

The public-preview command rejects every other database path, including the
tracked `db/stock.sqlite3`; health monitoring also treats a non-isolated recorded
database as unhealthy.

Inspect the current URL and verify both local and public health without
restarting either process:

```powershell
pwsh -File bin\public-preview-status.ps1
```

The status command checks both local and public responses for SZ, SH, and BJ. It
exits unsuccessfully if Rails, the tunnel, or any market endpoint is unavailable,
making it suitable for monitoring.

Install a self-healing check every 30 minutes with:

```powershell
pwsh -File bin\install-public-preview-monitor.ps1
```

The monitor makes two health checks 15 seconds apart before recovery, ignores
overlapping runs, and writes its decisions to `log/public-preview/monitor.log`. The
monitor trims this log after it reaches 1 MB, retaining the latest 1,000 lines.
Failed checks record Rails/tunnel state and per-market local/public status codes.
Because Quick Tunnel URLs are temporary, a recovery can assign a new URL; read
the current address with `bin\public-preview-status.ps1`.

On Linux, install the equivalent systemd-managed preview and self-healing check
with:

```sh
bin/install-public-preview-monitor.sh
```

The Rails server and Cloudflare tunnel run under
`stave-public-preview.service`. A timer checks local and public health twice
every 30 minutes before restarting that service. Inspect the current URL with
`bin/public-preview-status.sh` and view service decisions with:

```sh
journalctl --user -u stave-public-preview.service -u stave-public-preview-monitor.service
```

### Tests

Prepare the isolated test database once, then run the suite:

```powershell
$env:RAILS_ENV = "test"
bundle exec rails db:migrate
Remove-Item Env:RAILS_ENV
bundle exec rails test
```

The tests cover market routing, configurable data paths, resumable imports,
binary decoding, moving averages, regression alignment, stave deviation, trend
eligibility, and every currently reachable signal code.

One checkout runs one suite at a time. The test database is a single SQLite
file, and SQLite answers a lock upgrade with `SQLITE_BUSY` at once, so two
suites writing it together leave one of them failing with "database is
locked". To run a second suite beside the first, give it its own database:

```powershell
$env:RAILS_ENV = "test"
$env:STOCK_TEST_DATABASE = "tmp/test-alternate.sqlite3"
bundle exec rails db:test:prepare
Remove-Item Env:RAILS_ENV
bundle exec rails test
```

GitHub Actions runs the test database setup, pending-migration check, complete
test suite, Zeitwerk autoload check, PowerShell automation syntax check,
bundler-audit, Brakeman, schema consistency check, and whitespace validation on
every push and pull request.

### Troubleshooting

- **Dev-server restarts on Windows:** Puma's in-place restart, triggered by
  touching `tmp/restart.txt`, fails on this setup with
  `Errno::ENOENT - bin/rails` because the server is launched through
  `bundle.bat`. Restart the server manually instead of touching `restart.txt`.
- **Multiple Ruby installs:** The project requires Ruby 3.4.10 (see
  `.ruby-version`). If `ruby -v` reports an older version while
  `bundle exec rails` runs 3.4.x, put `C:\Ruby34-x64\bin` ahead of the older
  Ruby's `bin` directory on `PATH`.
