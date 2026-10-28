"""Event study of daily signals against forward-adjusted returns.

    python analyze.py OUT_DIR VIPDOC [--long BUY --short SELL]

Reads OUT_DIR/signals.parquet and OUT_DIR/adjusted.parquet (fetch_xdxr.py);
writes OUT_DIR/results.csv and prints the report tables.

signals.parquet is replay.py's output for the five-line engine, but any
signal source works if it has one row per (stock, date, window) for every
stock-day the rule could have picked from -- signal or not, because those
rows are the baseline:

    stock   str  sz000001, sh600000, bj920001 ...
    date    int  yyyymmdd
    window  str  a name for one variant of the rule
    signal  str  the reading that day, "" for none
    family  str  optional grouping of signals; without it, five-line codes
                 map through engine.FAMILY and any other signal is its own
                 family. "" or missing is the NONE (no signal) group.

Windows and families are read from the data. --long/--short name the two
families whose difference is tested as a spread (default BUY and SELL).

Method
* Entry at the close of the first trading day after the signal date D.
* Baseline: the same window's model universe on D -- every stock-day the
  engine produced a model for, signal or not -- so excess return is
  "versus the stocks this strategy could have picked from that day".
  An all-A-share market baseline is reported alongside.
* Each date contributes one observation (mean event return minus baseline);
  dates are equally weighted, so a day with 2,000 identical SAF1 readings
  does not count 2,000 times.
* h-day returns from consecutive dates overlap, so standard errors are
  Newey-West with lag h. Holm correction across the primary tests.
* Two event definitions: "state" (every day a stock sits in the family) and
  "entry" (the first day it moves into the family from anything else).
"""
import argparse
from math import erf, sqrt

import numpy as np
import pandas as pd

import engine as E

HORIZONS = (5, 10, 20, 60)
NONE = "NONE"


# --- statistics ----------------------------------------------------------

LAG_STEP = 1   # trading days between signal dates; set by set_lag_step


def set_lag_step(sig, prices):
    """Signals dated only every k-th trading day overlap over about h/k
    observations, not h. Daily signals (the five-line replay) give k = 1."""
    global LAG_STEP
    calendar = np.sort(prices["date"].unique())
    gaps = np.diff(np.searchsorted(calendar, np.sort(sig["date"].unique())))
    LAG_STEP = max(1, int(np.median(gaps))) if gaps.size else 1
    return LAG_STEP


def lag(h):
    """Newey-West lag, in observations, for an h-day holding period."""
    return max(1, -(-h // LAG_STEP))


def newey_west(x, lag):
    """Mean, NW standard error and t of a date-ordered series."""
    x = np.asarray(x, dtype=float)
    n = x.size
    if n < max(10, lag + 2):
        return np.nan, np.nan, np.nan
    m = x.mean()
    u = x - m
    s = u @ u / n
    for k in range(1, min(lag, n - 1) + 1):
        s += 2 * (1 - k / (lag + 1)) * (u[k:] @ u[:-k]) / n
    se = sqrt(max(s, 0) / n)
    return m, se, (m / se if se else np.nan)


def p_two_sided(t):
    return float("nan") if np.isnan(t) else 2 * (1 - 0.5 * (1 + erf(abs(t) / sqrt(2))))


def holm(pvals):
    p = np.asarray(pvals, dtype=float)
    order = np.argsort(np.where(np.isnan(p), np.inf, p))
    adj = np.full(p.size, np.nan)
    m = np.count_nonzero(~np.isnan(p))
    running = 0.0
    for rank, i in enumerate(order):
        if np.isnan(p[i]):
            continue
        running = max(running, min(1.0, (m - rank) * p[i]))
        adj[i] = running
    return adj


# --- data ----------------------------------------------------------------

def load_signals(out_dir, vipdoc):
    """signals.parquet with a `family` column; pre-2025 Beijing codes are
    dropped in favour of the 92xxxx code that carries the same history."""
    sig = pd.read_parquet(f"{out_dir}/signals.parquet")
    aliases = E.bj_aliases(vipdoc)
    sig = sig[~sig["stock"].isin(aliases.keys())].copy()
    sig["window"] = sig["window"].astype(str)
    sig["signal"] = sig["signal"].fillna("").astype(str)
    if "family" in sig:
        sig["family"] = sig["family"].fillna("").astype(str).replace("", NONE)
    else:
        sig["family"] = sig["signal"].map(lambda s: E.FAMILY.get(s, s or NONE))
    return sig


def windows_of(sig):
    return sorted(sig["window"].unique())


def families_of(sig):
    """Families present in the data, the no-signal group last."""
    present = set(sig["family"])
    return sorted(present - {NONE}) + ([NONE] if NONE in present else [])


def spread_series(u, kind, h, long, short):
    """Per date: mean h-day return of the long family minus the short one,
    on dates where both have events."""
    col = f"r{h}"
    sel = u if kind == "state" else u[u["entry"]]
    means = sel.dropna(subset=[col]).groupby(["date", "family"])[col].mean().unstack()
    if not {long, short} <= set(means.columns):
        return pd.Series(dtype=float)
    return (means[long] - means[short]).dropna()


def daily_limit(stock):
    """Widest legal daily move for the board (plus rounding slack)."""
    if stock.startswith("bj"):
        return 0.305
    if stock.startswith(("sz30", "sh68")):
        return 0.205
    return 0.105


def impossible_days(prices):
    """Flag adjusted daily moves no A-share can make: beyond the board's price
    limit outside a stock's first five sessions in the data. They mark an
    ex-rights event the adjustment got wrong (bankruptcy-reorganisation
    conversions are dated differently by different vendors)."""
    g = prices.groupby("stock", sort=False)["close"]
    r = (prices["close"] / g.shift(1) - 1).abs()
    limit = prices["stock"].map({s: daily_limit(s) for s in prices["stock"].unique()})
    first = prices["date"].eq(prices.groupby("stock")["date"].transform("min"))
    listed_late = prices.groupby("stock")["date"].transform("min") > prices["date"].min()
    session = g.cumcount()
    ipo_window = listed_late & (session < 5)
    return (r > limit) & ~first & ~ipo_window


def forward_returns(prices):
    """Per (stock, signal date) -> entry next trading day, returns at each h.

    Returned frame is indexed by (stock, date) for every trading date,
    where `date` is the would-be signal date whose entry is the following row.
    Prices must be multiplicatively adjusted: subtractive qfq series (Tencent,
    Eastmoney fqt=1) go to zero or negative for heavy dividend payers.
    A return whose holding window crosses an impossible day is dropped.
    """
    prices = prices.sort_values(["stock", "date"]).reset_index(drop=True)
    bad = impossible_days(prices).astype(int)
    g = prices.groupby("stock", sort=False)["close"]
    gb = bad.groupby(prices["stock"], sort=False)
    bad_cum = gb.cumsum()
    out = pd.DataFrame({"stock": prices["stock"].values, "date": prices["date"].values})
    entry = g.shift(-1)
    entry_bad = bad_cum.groupby(prices["stock"], sort=False).shift(-1)
    dropped = {}
    for h in HORIZONS:
        exit_ = g.shift(-1 - h)
        exit_bad = bad_cum.groupby(prices["stock"], sort=False).shift(-1 - h)
        r = exit_.values / entry.values - 1
        r[(entry.values <= 0) | (exit_.values <= 0)] = np.nan
        crosses = (exit_bad.values - entry_bad.values) > 0
        dropped[h] = int(np.count_nonzero(crosses & ~np.isnan(r)))
        r[crosses] = np.nan
        out[f"r{h}"] = r
    print(f"impossible adjusted moves: {int(bad.sum())} days in "
          f"{prices.loc[bad.astype(bool), 'stock'].nunique()} stocks; "
          f"stock-day returns dropped by horizon: {dropped}")
    return out


def attach_returns(sig, fwd):
    """Join returns on signal date; a signal on a non-trading day for that
    stock (suspension) takes the last trading row on or before it."""
    sig = sig.sort_values("date")
    fwd = fwd.sort_values("date")
    return pd.merge_asof(sig, fwd, on="date", by="stock", direction="backward",
                         allow_exact_matches=True)


def mark_entries(df):
    """entry=True on the first day of a run in the same family (per stock+window).
    A day whose previous trading day had no model counts as a new run."""
    df = df.sort_values(["window", "stock", "date"])
    prev_fam = df.groupby(["window", "stock"], observed=True)["family"].shift(1)
    prev_date = df.groupby(["window", "stock"], observed=True)["date"].shift(1)
    df["prev_date"] = prev_date
    df["entry"] = prev_fam.ne(df["family"])
    return df


# --- study ---------------------------------------------------------------

def excess_series(events, universe, h, baseline):
    col = f"r{h}"
    ev = events.dropna(subset=[col]).groupby("date")[col].agg(["mean", "median", "size"])
    base = baseline[h]
    j = ev.join(base, how="inner")
    j = j[j["base_n"] >= 20]
    return j


def summarise(label, events, baseline, h, stats_rows, extra=None):
    j = excess_series(events, None, h, baseline)
    if j.empty:
        return
    xs = (j["mean"] - j["base_mean"]).values
    m, se, t = newey_west(xs, lag(h))
    rets = events[f"r{h}"].dropna()
    raw = rets.mean()
    win = (rets > 0).mean()
    med_xs = np.mean(j["median"].values - j["base_median"].values)
    row = dict(label=label, h=h, n_events=int(j["size"].sum()), n_dates=len(j),
               raw=raw, win=win, excess=m, se=se, t=t, p=p_two_sided(t), median_excess=med_xs)
    if extra:
        row.update(extra)
    stats_rows.append(row)


def build_baseline(universe):
    out = {}
    for h in HORIZONS:
        col = f"r{h}"
        g = universe.dropna(subset=[col]).groupby("date")[col]
        out[h] = pd.DataFrame({"base_mean": g.mean(), "base_median": g.median(), "base_n": g.size()})
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("out"); p.add_argument("vipdoc")
    p.add_argument("--long", default="BUY", help="spread: long family (default BUY)")
    p.add_argument("--short", default="SELL", help="spread: short family (default SELL)")
    p.add_argument("--prices", help="adjusted closes (default OUT/adjusted.parquet)")
    a = p.parse_args()
    out_dir = a.out
    sig = load_signals(out_dir, a.vipdoc)
    prices = pd.read_parquet(a.prices or f"{out_dir}/adjusted.parquet")
    if set_lag_step(sig, prices) > 1:
        print(f"signals every {LAG_STEP} trading days: overlap lags scaled to match")
    windows, families = windows_of(sig), families_of(sig)
    spread_name = f"{a.long}-{a.short}"

    fwd = forward_returns(prices)
    sig = attach_returns(sig, fwd)
    sig = mark_entries(sig)
    sig["year_of"] = sig["date"] // 10000

    # all-A-share market baseline on each signal date
    market = build_baseline(fwd)
    # the previous report's baseline: every trading day of every stock that
    # ever produced a signal, whether or not it had a model that day
    ever = set(sig.loc[sig["signal"] != "", "stock"])
    legacy = build_baseline(fwd[fwd["stock"].isin(ever)])

    rows = []
    for window in windows:
        u = sig[sig["window"] == window]
        base = build_baseline(u)
        for fam in families:
            for kind in ("state", "entry"):
                ev = u[u["family"] == fam]
                if kind == "entry":
                    ev = ev[ev["entry"]]
                for h in HORIZONS:
                    summarise(f"{window}|{fam}|{kind}|universe", ev, base, h, rows,
                              dict(window=window, family=fam, kind=kind, baseline="universe"))
                    summarise(f"{window}|{fam}|{kind}|market", ev, market, h, rows,
                              dict(window=window, family=fam, kind=kind, baseline="market"))
                    if kind == "state":
                        summarise(f"{window}|{fam}|state|legacy", ev, legacy, h, rows,
                                  dict(window=window, family=fam, kind=kind, baseline="legacy"))
                    if kind == "state" and fam in (a.long, a.short):
                        for y, ey in ev.groupby("year_of"):
                            summarise(f"{window}|{fam}|state|universe|{y}", ey, base, h, rows,
                                      dict(window=window, family=fam, kind="state",
                                           baseline="universe", year=int(y)))
        # per signal code, state, universe baseline
        for code, ev in u.groupby("signal"):
            for h in HORIZONS:
                summarise(f"{window}|code:{code or 'NONE'}", ev, base, h, rows,
                          dict(window=window, family="code", code=code or "NONE",
                               kind="state", baseline="universe"))
        # long minus short spread on dates where both exist
        for kind in ("state", "entry"):
            for h in HORIZONS:
                d = spread_series(u, kind, h, a.long, a.short)
                if d.empty:
                    continue
                m, se, t = newey_west(d.values, lag(h))
                rows.append(dict(label=f"{window}|{spread_name}|{kind}", window=window,
                                 family=spread_name, kind=kind, baseline="spread", h=h,
                                 n_dates=len(d), excess=m, se=se, t=t, p=p_two_sided(t)))

    # five-line only: two-horizon agreement, as SignalFamily.classify does it
    if {"lohas", "year"} <= set(windows):
        both = sig.pivot_table(index=["stock", "date"], columns="window", values="signal",
                               aggfunc="first").dropna()
        lf = both["lohas"].map(E.FAMILY)
        yf = both["year"].map(E.FAMILY)
        agree = np.where((lf == "SELL") | (yf == "SELL"), "sell",
                         np.where((lf == "BUY") & (yf == "BUY"), "buy", "watch"))
        both = both.assign(agree=agree).reset_index()[["stock", "date", "agree"]]
        both = attach_returns(both, fwd)
        base = build_baseline(both)
        for fam in ("buy", "sell", "watch"):
            for h in HORIZONS:
                summarise(f"agree|{fam}", both[both["agree"] == fam], base, h, rows,
                          dict(window="both", family=fam, kind="state", baseline="universe"))

    res = pd.DataFrame(rows)
    if "year" not in res:
        res["year"] = np.nan
    signal_families = [f for f in families if f != NONE]
    primary = (res["baseline"] == "universe") & res["kind"].eq("state") & res["year"].isna() \
        & res["family"].isin(signal_families) & res["window"].isin(windows)
    res["p_holm"] = np.nan
    res.loc[primary, "p_holm"] = holm(res.loc[primary, "p"].values)
    spread = res["family"].eq(spread_name)
    res.loc[spread, "p_holm"] = holm(res.loc[spread, "p"].values)
    codes = res["family"].eq("code")
    res.loc[codes, "p_holm"] = holm(res.loc[codes, "p"].values)
    res.to_csv(f"{out_dir}/results.csv", index=False)

    pd.set_option("display.width", 200)
    pd.set_option("display.max_rows", 500)
    fmt = res.copy()
    for c in ("raw", "win", "excess", "se", "median_excess"):
        if c in fmt:
            fmt[c] = (fmt[c] * 100).round(2)
    fmt["t"] = fmt["t"].round(1)
    cols = ["label", "h", "n_events", "n_dates", "raw", "win", "excess", "t", "p_holm", "median_excess"]
    print(fmt[[c for c in cols if c in fmt]].to_string(index=False))
    print("\nuniverse sizes:", sig.groupby("window").size().to_dict(),
          "stocks:", sig.groupby("window")["stock"].nunique().to_dict())


if __name__ == "__main__":
    main()
