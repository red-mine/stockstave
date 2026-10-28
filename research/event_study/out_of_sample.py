"""Out-of-sample checks of an event study's findings.

    python out_of_sample.py OUT_DIR VIPDOC [--study 20210104-20261013]
        [--holdout 20120101-20201231 | --holdout none]
        [--long BUY --short SELL] [--claims five_line_claims.json] [--cost 0.0011]

OUT_DIR holds signals.parquet and adjusted.parquet covering both periods
(see analyze.py for the signals.parquet format). For the five-line engine:

    python replay.py $VIP $OUT --start 20120101
    python fetch_xdxr.py $VIP $OUT --beg 20111201
    python out_of_sample.py $OUT $VIP --claims five_line_claims.json

All parts use analyze.py's method (next-day-close entry, date-weighted
excess, Newey-West errors). Windows and families are read from the data.

1. Study period: the tables the findings were read from. With the study's
   own dates this must reproduce its report, or nothing below can be trusted.
2. Holdout: a period the study never looked at, with prices cut at its end
   so no return reaches into later data. Each claim in --claims is tested in
   the direction it states.
3. By year, every window: long-short spread 10d, short family vs pool 20d,
   no-signal stocks vs the whole market 60d.
4. Walk-forward: for each year Y after the first, pick the long-only rule
   (window x family x event kind x horizon) with the best net-of-cost t on
   everything that had finished before Y, then hold it through Y. Picking on
   the past and scoring on the next year is what someone using the rule live
   would have got.

A claims file is a JSON list; `label` is a row label of the tables
(window|family|state|universe, window|family|state|market,
window|LONG-SHORT|entry, window|code:SIGNAL), `sign` the direction claimed:

    [{"text": "year SELL vs pool, 20d", "label": "year|SELL|state|universe",
      "h": 20, "sign": -1}]
"""
import argparse
import gc
import json

import numpy as np
import pandas as pd

import analyze as A

COST = 0.0011            # round trip: 0.03% buy commission + 0.08% sell side


def span(text):
    if text.lower() == "none":
        return None
    beg, end = (int(x) for x in text.split("-"))
    return beg, end


def period(sig, prices, beg, end):
    """Signals dated in [beg, end] with returns from prices up to `end`.
    Only the columns the statistics read are kept: a daily full-market
    signal set is over ten million rows."""
    fwd = A.forward_returns(prices[prices["date"] <= end])
    s = sig[(sig["date"] >= beg) & (sig["date"] <= end)].drop(
        columns=[f"r{h}" for h in A.HORIZONS], errors="ignore")
    s = A.attach_returns(s, fwd)
    s = s[["date", "window", "signal", "family", "entry"] + [f"r{h}" for h in A.HORIZONS]]
    return s, fwd


def window_rows(s, window, cfg):
    """The rows of one window, without a copy when it is the only one."""
    return s if len(cfg.windows) == 1 else s[s["window"] == window]


def events(u, fam, kind):
    ev = u[u["family"] == fam]
    return ev[ev["entry"]] if kind == "entry" else ev


def spread(u, kind, h, cfg):
    d = A.spread_series(u, kind, h, cfg.long, cfg.short)
    if d.empty:
        return np.nan, np.nan
    m, _, t = A.newey_west(d.values, A.lag(h))
    return m, t


def table(s, fwd, cfg):
    """The study's tables for one period: families, spreads, codes."""
    market = A.build_baseline(fwd)
    rows = []
    for window in cfg.windows:
        u = window_rows(s, window, cfg)
        base = A.build_baseline(u)
        for fam in cfg.families:
            for kind in ("state", "entry"):
                ev = events(u, fam, kind)
                for h in A.HORIZONS:
                    for name, b in (("universe", base), ("market", market)):
                        A.summarise(f"{window}|{fam}|{kind}|{name}", ev, b, h, rows,
                                    dict(window=window, family=fam, kind=kind, baseline=name))
        for code in sorted(c for c in u["signal"].unique() if c):
            for h in A.HORIZONS:
                A.summarise(f"{window}|code:{code}", u[u["signal"] == code], base, h, rows,
                            dict(window=window, family="code", code=code, kind="state",
                                 baseline="universe"))
        for kind in ("state", "entry"):
            for h in A.HORIZONS:
                m, t = spread(u, kind, h, cfg)
                rows.append(dict(label=f"{window}|{cfg.spread}|{kind}", window=window,
                                 family=cfg.spread, kind=kind, baseline="spread", h=h,
                                 excess=m, t=t, p=A.p_two_sided(t)))
    res = pd.DataFrame(rows)
    primary = res["baseline"].eq("universe") & res["kind"].eq("state") \
        & res["family"].isin(cfg.signal_families)
    res["p_holm"] = np.nan
    res.loc[primary, "p_holm"] = A.holm(res.loc[primary, "p"].values)
    sp = res["family"].eq(cfg.spread)
    res.loc[sp, "p_holm"] = A.holm(res.loc[sp, "p"].values)
    return res


def pick(res, label, h):
    r = res[(res["label"] == label) & (res["h"] == h)]
    return r.iloc[0] if len(r) else None


def claims_report(res, claims, title):
    if not claims:
        return
    print(f"\n== {title} ==")
    print(f"{'claim':58s} {'excess':>8s} {'t':>6s}  same sign & |t|>=2?")
    holm_in = []
    for c in claims:
        text, sign = c["text"], c["sign"]
        r = pick(res, c["label"], c["h"])
        if r is None or pd.isna(r["excess"]):
            print(f"{text:58s}      n/a")
            continue
        ok = np.sign(r["excess"]) == sign and abs(r["t"]) >= 2
        # one-sided p in the claimed direction, Holm-corrected across claims below
        holm_in.append(A.p_two_sided(r["t"]) / 2 if np.sign(r["t"]) == sign
                       else 1 - A.p_two_sided(r["t"]) / 2)
        print(f"{text:58s} {r['excess'] * 100:+7.2f}% {r['t']:6.1f}  {'yes' if ok else 'no'}")
    adj = A.holm(holm_in)
    print("one-sided Holm p across claims:", " ".join(f"{p:.3f}" for p in adj))


def main_table(res, title, cfg):
    print(f"\n== {title}: excess vs model pool, state, % (t) ==")
    na = "     n/a      "
    for window in cfg.windows:
        for fam in cfg.signal_families:
            cells = []
            for h in A.HORIZONS:
                r = pick(res, f"{window}|{fam}|state|universe", h)
                cells.append(na if r is None else f"{r['excess'] * 100:+6.2f} ({r['t']:+4.1f})")
            print(f"{window:5s} {fam:4s} " + "  ".join(cells))
    for window in cfg.windows:
        cells = []
        for h in A.HORIZONS:
            r = pick(res, f"{window}|{cfg.spread}|entry", h)
            cells.append(na if r is None or pd.isna(r["excess"]) else
                         f"{r['excess'] * 100:+6.2f} ({r['t']:+4.1f}) p_holm {r['p_holm']:.2f}")
        print(f"{window:5s} {cfg.spread} entry  " + "  ".join(cells))


def by_year(s, fwd, cfg, first, last):
    fmt = lambda r: "   n/a        " if r is None or np.isnan(r["t"]) else \
        f"{r['excess'] * 100:+6.2f} ({r['t']:+4.1f})"
    market = A.build_baseline(fwd)
    for window in cfg.windows:
        u = window_rows(s, window, cfg)
        base = A.build_baseline(u)
        print(f"\n== by year, {window} window: {cfg.spread} entry 10d / {cfg.short} vs pool 20d"
              f" / no-signal vs market 60d ==")
        for y in range(first, last + 1):
            uy = u[(u["date"] // 10000) == y]
            m10, t10 = spread(uy, "entry", 10, cfg)
            rows = []
            A.summarise("short", uy[uy["family"] == cfg.short], base, 20, rows)
            A.summarise("none", uy[uy["family"] == A.NONE], market, 60, rows)
            short = next((r for r in rows if r["label"] == "short"), None)
            none = next((r for r in rows if r["label"] == "none"), None)
            sp = "   n/a        " if np.isnan(m10) else f"{m10 * 100:+6.2f} ({t10:+4.1f})"
            print(f"{y}  spread {sp}   {cfg.short.lower()} {fmt(short)}   no-signal {fmt(none)}")


# --- walk-forward --------------------------------------------------------

def candidate_series(s, fwd, cfg):
    """Daily (event mean - baseline) for every long-only rule, both baselines."""
    market = A.build_baseline(fwd)
    out = {}
    for window in cfg.windows:
        u = window_rows(s, window, cfg)
        base = A.build_baseline(u)
        for fam in cfg.families:
            for kind in ("state", "entry"):
                ev = events(u, fam, kind)
                for h in A.HORIZONS:
                    for name, b in (("universe", base), ("market", market)):
                        j = A.excess_series(ev, None, h, b)
                        out[(window, fam, kind, h, name)] = (j["mean"] - j["base_mean"]).sort_index()
    return out


def walk_forward(series, calendar, baseline, first_year, last_year, cost):
    rows = []
    pos = {d: i for i, d in enumerate(calendar)}
    for y in range(first_year, last_year + 1):
        start = next((d for d in calendar if d >= y * 10000), None)
        if start is None:
            break
        cut = pos[start]
        best = None
        for key, x in series.items():
            if key[4] != baseline:
                continue
            h = key[3]
            # in-sample: only signals whose exit (entry + h days) closed before Y
            idx = np.array([pos[d] for d in x.index])
            train = x[(idx + 1 + h) < cut]
            if len(train) < max(24, 120 // A.LAG_STEP):   # about half a year of dates
                continue
            m, _, t = A.newey_west(train.values - cost, A.lag(h))
            if np.isnan(t):
                continue
            if best is None or t > best[1]:
                best = (key, t, m)
        if best is None:
            continue
        key, t_in, m_in = best
        x = series[key]
        test = x[(x.index >= y * 10000) & (x.index < (y + 1) * 10000)]
        if test.empty:
            continue
        h = key[3]
        m, _, t = A.newey_west(test.values - cost, A.lag(h))
        rows.append(dict(year=y, rule=f"{key[0]} {key[1]} {key[2]} {h}d", h=h,
                         in_net=m_in, in_t=t_in, out_net=m, out_t=t,
                         out_net_20d=m * 20 / h, days=len(test)))
    return pd.DataFrame(rows)


def walk_report(wf, title, cost):
    print(f"\n== walk-forward, {title} (net of {cost * 100:.2f}% round trip) ==")
    if wf.empty:
        print("no years")
        return
    for r in wf.itertuples():
        past = f"{r.year}  {r.rule:24s} past {r.in_net * 100:+6.2f}% (t {r.in_t:+4.1f})"
        if np.isnan(r.out_net):
            print(f"{past}  ->  that year n/a ({r.days} signal dates, too few for the overlap)")
            continue
        print(f"{past}  ->  that year {r.out_net * 100:+6.2f}% (t {r.out_t:+4.1f})"
              f"  = {r.out_net_20d * 100:+5.2f}% per 20d")
    scored = wf.dropna(subset=["out_net"])
    unscored = len(wf) - len(scored)
    pos = (scored["out_net"] > 0).sum()
    print(f"years positive: {pos}/{len(scored)}"
          + (f" ({unscored} not scored)" if unscored else "")
          + f"; mean per 20d {scored['out_net_20d'].mean() * 100:+.2f}%,"
          f" median {scored['out_net_20d'].median() * 100:+.2f}%")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("out"); p.add_argument("vipdoc")
    p.add_argument("--study", type=span, default=(20210104, 20261013),
                   help="period the findings were read from, BEG-END (default 20210104-20261013)")
    p.add_argument("--holdout", type=span, default=(20120101, 20201231),
                   help="period the study never saw, BEG-END or none (default 20120101-20201231)")
    p.add_argument("--long", default="BUY", help="spread: long family (default BUY)")
    p.add_argument("--short", default="SELL", help="spread: short family (default SELL)")
    p.add_argument("--claims", help="JSON list of findings to test on the holdout")
    p.add_argument("--prices", help="adjusted closes (default OUT/adjusted.parquet)")
    p.add_argument("--cost", type=float, default=COST,
                   help=f"round-trip cost for the walk-forward (default {COST})")
    cfg = p.parse_args()
    out_dir = cfg.out
    claims = json.load(open(cfg.claims, encoding="utf-8")) if cfg.claims else []

    sig = A.load_signals(out_dir, cfg.vipdoc)
    sig = A.mark_entries(sig)           # on the full history, so a period's
                                        # first day is not an entry for all
    sig = sig.drop(columns=["prev_date"])
    prices = pd.read_parquet(cfg.prices or f"{out_dir}/adjusted.parquet")
    if A.set_lag_step(sig, prices) > 1:
        print(f"signals every {A.LAG_STEP} trading days: overlap lags scaled to match")
    cfg.windows = A.windows_of(sig)
    cfg.families = A.families_of(sig)
    cfg.signal_families = [f for f in cfg.families if f != A.NONE]
    cfg.spread = f"{cfg.long}-{cfg.short}"
    pd.set_option("display.width", 200)

    study_beg, study_end = cfg.study
    s, fwd = period(sig, prices, study_beg, study_end)
    study = table(s, fwd, cfg)
    study.to_csv(f"{out_dir}/oos_study.csv", index=False)
    main_table(study, f"study period {study_beg}..{study_end}", cfg)
    claims_report(study, claims, "claims on the study period (should match the report)")

    beg, end = study_beg, study_end
    del s, fwd                          # one period in memory at a time
    gc.collect()
    if cfg.holdout:
        hold_beg, hold_end = cfg.holdout
        s, fwd = period(sig, prices, hold_beg, hold_end)
        hold = table(s, fwd, cfg)
        hold.to_csv(f"{out_dir}/oos_holdout.csv", index=False)
        main_table(hold, f"holdout {hold_beg}..{hold_end}", cfg)
        claims_report(hold, claims, "claims on the holdout")
        beg, end = min(beg, hold_beg), max(end, hold_end)
        del s, fwd
        gc.collect()

    s, fwd = period(sig, prices, beg, end)
    del sig, prices
    gc.collect()
    by_year(s, fwd, cfg, beg // 10000, end // 10000)

    series = candidate_series(s, fwd, cfg)
    calendar = sorted(fwd["date"].unique())
    for baseline in ("market", "universe"):
        wf = walk_forward(series, calendar, baseline, beg // 10000 + 1, end // 10000, cfg.cost)
        wf.to_csv(f"{out_dir}/oos_walk_forward_{baseline}.csv", index=False)
        walk_report(wf, f"picked and scored vs {baseline}", cfg.cost)


if __name__ == "__main__":
    main()
