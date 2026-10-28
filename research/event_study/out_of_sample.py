"""Out-of-sample checks of the event study's findings.

    python out_of_sample.py OUT_DIR VIPDOC

OUT_DIR must hold signals.parquet and adjusted.parquet built from 2012:

    python replay.py $VIP $OUT --start 20120101
    python fetch_xdxr.py $VIP $OUT --beg 20111201

Three parts, all with analyze.py's method (next-day-close entry, date-
weighted excess, Newey-West errors):

1. Reproduction: signal dates 2021-01-04..2026-10-13 must give the numbers
   in docs/event_study.md, or nothing below can be trusted.
2. Holdout: signal dates 2012..2020, with prices cut at 2020-12-31 so no
   return reaches the period the study was written on. Each finding the
   study reported is tested in the direction it claimed.
3. Walk-forward: for each year Y, pick the long-only rule (window x family x
   event kind x horizon) with the best net-of-cost t on everything that had
   finished before Y, then hold it through Y. Picking on the past and
   scoring on the next year is what someone using the engine live would
   have got.
"""
import sys

import numpy as np
import pandas as pd

import analyze as A
import engine as E

COST = 0.0011            # round trip: 0.03% buy commission + 0.08% sell side
STUDY = (20210104, 20261013)
HOLDOUT = (20120101, 20201231)
FAMILIES = ("BUY", "SELL", "SOAR", "WAT", "NONE")


def load(out_dir, vipdoc):
    sig = pd.read_parquet(f"{out_dir}/signals.parquet")
    prices = pd.read_parquet(f"{out_dir}/adjusted.parquet")
    aliases = E.bj_aliases(vipdoc)
    sig = sig[~sig["stock"].isin(aliases.keys())].copy()
    sig["window"] = sig["window"].astype(str)
    sig["family"] = sig["signal"].map(E.FAMILY)
    sig = A.mark_entries(sig)           # on the full history, so a period's
    return sig, prices                  # first day is not an "entry" for all


def period(sig, prices, beg, end):
    """Signals dated in [beg, end] with returns from prices up to `end`."""
    fwd = A.forward_returns(prices[prices["date"] <= end])
    s = sig[(sig["date"] >= beg) & (sig["date"] <= end)].drop(
        columns=[f"r{h}" for h in A.HORIZONS], errors="ignore")
    s = A.attach_returns(s, fwd)
    return s, fwd


def events(u, fam, kind):
    ev = u[u["family"] == fam]
    return ev[ev["entry"]] if kind == "entry" else ev


def spread(u, kind, h):
    col = f"r{h}"
    sel = u if kind == "state" else u[u["entry"]]
    means = sel.dropna(subset=[col]).groupby(["date", "family"])[col].mean().unstack()
    if not {"BUY", "SELL"} <= set(means.columns):
        return np.nan, np.nan
    d = (means["BUY"] - means["SELL"]).dropna()
    m, _, t = A.newey_west(d.values, h)
    return m, t


def table(s, fwd):
    """The study's tables for one period: families, spreads, trend filter, codes."""
    market = A.build_baseline(fwd)
    rows = []
    for window in ("lohas", "year"):
        u = s[s["window"] == window]
        base = A.build_baseline(u)
        for fam in FAMILIES:
            for kind in ("state", "entry"):
                ev = events(u, fam, kind)
                for h in A.HORIZONS:
                    for name, b in (("universe", base), ("market", market)):
                        A.summarise(f"{window}|{fam}|{kind}|{name}", ev, b, h, rows,
                                    dict(window=window, family=fam, kind=kind, baseline=name))
        for code in ("BUY4", "BUY5", "SAF1", "CHP0"):
            for h in A.HORIZONS:
                A.summarise(f"{window}|code:{code}", u[u["signal"] == code], base, h, rows,
                            dict(window=window, family="code", code=code, kind="state",
                                 baseline="universe"))
        for kind in ("state", "entry"):
            for h in A.HORIZONS:
                m, t = spread(u, kind, h)
                rows.append(dict(label=f"{window}|BUY-SELL|{kind}", window=window,
                                 family="BUY-SELL", kind=kind, baseline="spread", h=h,
                                 excess=m, t=t, p=A.p_two_sided(t)))
    res = pd.DataFrame(rows)
    primary = res["baseline"].eq("universe") & res["kind"].eq("state") \
        & res["family"].isin(["BUY", "SELL", "SOAR", "WAT"])
    res["p_holm"] = np.nan
    res.loc[primary, "p_holm"] = A.holm(res.loc[primary, "p"].values)
    sp = res["family"].eq("BUY-SELL")
    res.loc[sp, "p_holm"] = A.holm(res.loc[sp, "p"].values)
    return res


def pick(res, label, h):
    r = res[(res["label"] == label) & (res["h"] == h)]
    return r.iloc[0] if len(r) else None


# Findings of docs/event_study.md, each with the sign it claimed.
CLAIMS = [
    ("year BUY-SELL spread, entry, 5d  (study +0.35%, t 3.1)", "year|BUY-SELL|entry", 5, +1),
    ("year BUY-SELL spread, entry, 10d (study +0.65%, t 3.3)", "year|BUY-SELL|entry", 10, +1),
    ("year SELL vs model pool, 20d     (study -1.21%, t -2.8)", "year|SELL|state|universe", 20, -1),
    ("year BUY vs model pool, 60d      (study +0.51%, t 2.0)", "year|BUY|state|universe", 60, +1),
    ("lohas no-signal vs market, 60d   (study -2.9%,  t -3.2)", "lohas|NONE|state|market", 60, -1),
    ("year no-signal vs market, 60d    (trend filter, year)", "year|NONE|state|market", 60, -1),
    ("lohas BUY4 vs model pool, 20d    (study -1.40%, t -2.9)", "lohas|code:BUY4", 20, -1),
    ("lohas BUY5 vs model pool, 20d    (study negative)", "lohas|code:BUY5", 20, -1),
    ("year BUY5 vs model pool, 20d     (study negative)", "year|code:BUY5", 20, -1),
]


def claims_report(res, title):
    print(f"\n== {title} ==")
    print(f"{'claim':58s} {'excess':>8s} {'t':>6s}  same sign & |t|>=2?")
    holm_in = []
    for text, label, h, sign in CLAIMS:
        r = pick(res, label, h)
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


def main_table(res, title):
    print(f"\n== {title}: excess vs model pool, state, % (t) ==")
    for window in ("lohas", "year"):
        for fam in ("BUY", "SELL", "SOAR", "WAT"):
            cells = []
            for h in A.HORIZONS:
                r = pick(res, f"{window}|{fam}|state|universe", h)
                cells.append("     n/a      " if r is None else
                             f"{r['excess'] * 100:+6.2f} ({r['t']:+4.1f})")
            print(f"{window:5s} {fam:4s} " + "  ".join(cells))
    for window in ("lohas", "year"):
        cells = []
        for h in A.HORIZONS:
            r = pick(res, f"{window}|BUY-SELL|entry", h)
            cells.append(f"{r['excess'] * 100:+6.2f} ({r['t']:+4.1f}) p_holm {r['p_holm']:.2f}")
        print(f"{window:5s} BUY-SELL entry  " + "  ".join(cells))


# --- walk-forward --------------------------------------------------------

def candidate_series(s, fwd):
    """Daily (event mean - baseline) for every long-only rule, both baselines."""
    market = A.build_baseline(fwd)
    out = {}
    for window in ("lohas", "year"):
        u = s[s["window"] == window]
        base = A.build_baseline(u)
        for fam in FAMILIES:
            for kind in ("state", "entry"):
                ev = events(u, fam, kind)
                for h in A.HORIZONS:
                    for name, b in (("universe", base), ("market", market)):
                        j = A.excess_series(ev, None, h, b)
                        out[(window, fam, kind, h, name)] = (j["mean"] - j["base_mean"]).sort_index()
    return out


def walk_forward(series, calendar, baseline, first_year, last_year):
    rows = []
    pos = {d: i for i, d in enumerate(calendar)}
    for y in range(first_year, last_year + 1):
        start = next(d for d in calendar if d >= y * 10000)
        cut = pos[start]
        best = None
        for key, x in series.items():
            if key[4] != baseline:
                continue
            h = key[3]
            # in-sample: only signals whose exit (entry + h days) closed before Y
            idx = np.array([pos[d] for d in x.index])
            train = x[(idx + 1 + h) < cut]
            if len(train) < 120:
                continue
            m, _, t = A.newey_west(train.values - COST, h)
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
        m, _, t = A.newey_west(test.values - COST, h)
        rows.append(dict(year=y, rule=f"{key[0]} {key[1]} {key[2]} {h}d", h=h,
                         in_net=m_in, in_t=t_in, out_net=m, out_t=t,
                         out_net_20d=m * 20 / h, days=len(test)))
    return pd.DataFrame(rows)


def walk_report(wf, title):
    print(f"\n== walk-forward, {title} (net of {COST * 100:.2f}% round trip) ==")
    if wf.empty:
        print("no years")
        return
    for r in wf.itertuples():
        print(f"{r.year}  {r.rule:24s} past {r.in_net * 100:+6.2f}% (t {r.in_t:+4.1f})"
              f"  ->  that year {r.out_net * 100:+6.2f}% (t {r.out_t:+4.1f})"
              f"  = {r.out_net_20d * 100:+5.2f}% per 20d")
    pos = (wf["out_net"] > 0).sum()
    print(f"years positive: {pos}/{len(wf)}; mean per 20d {wf['out_net_20d'].mean() * 100:+.2f}%,"
          f" median {wf['out_net_20d'].median() * 100:+.2f}%")


def main():
    out_dir, vipdoc = sys.argv[1], sys.argv[2]
    sig, prices = load(out_dir, vipdoc)
    pd.set_option("display.width", 200)

    s, fwd = period(sig, prices, *STUDY)
    study = table(s, fwd)
    study.to_csv(f"{out_dir}/oos_study.csv", index=False)
    main_table(study, f"reproduction {STUDY[0]}..{STUDY[1]}")
    claims_report(study, "claims on the study period (should match the report)")

    s, fwd = period(sig, prices, *HOLDOUT)
    hold = table(s, fwd)
    hold.to_csv(f"{out_dir}/oos_holdout.csv", index=False)
    main_table(hold, f"holdout {HOLDOUT[0]}..{HOLDOUT[1]}")
    claims_report(hold, "claims on the holdout")

    # per-year spread and sell warning across the whole span
    s, fwd = period(sig, prices, HOLDOUT[0], STUDY[1])
    print("\n== by year, year window: BUY-SELL entry 10d / SELL vs pool 20d / no-signal vs market 60d ==")
    for y in range(2012, 2027):
        sy = s[(s["date"] // 10000) == y]
        m10, t10 = spread(sy[sy["window"] == "year"], "entry", 10)
        rows = []
        uy = s[s["window"] == "year"]
        A.summarise("sell", sy[(sy["window"] == "year") & (sy["family"] == "SELL")],
                    A.build_baseline(uy), 20, rows)
        A.summarise("none", sy[(sy["window"] == "year") & (sy["family"] == "NONE")],
                    A.build_baseline(fwd), 60, rows)
        sell = next((r for r in rows if r["label"] == "sell"), None)
        none = next((r for r in rows if r["label"] == "none"), None)
        fmt = lambda r: "   n/a        " if r is None else f"{r['excess'] * 100:+6.2f} ({r['t']:+4.1f})"
        print(f"{y}  spread {m10 * 100:+6.2f} ({t10:+4.1f})   sell {fmt(sell)}   no-signal {fmt(none)}")

    series = candidate_series(s, fwd)
    calendar = sorted(fwd["date"].unique())
    for baseline in ("market", "universe"):
        wf = walk_forward(series, calendar, baseline, 2013, 2026)
        wf.to_csv(f"{out_dir}/oos_walk_forward_{baseline}.csv", index=False)
        walk_report(wf, f"picked and scored vs {baseline}")


if __name__ == "__main__":
    main()
