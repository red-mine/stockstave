"""Value, profitability and earnings-surprise signals from quarterly reports.

    python fundamental_signals.py FINANCIALS_PARQUET ADJUSTED_PARQUET VIPDOC OUT_DIR
        [--start 20120101] [--every 5]

FINANCIALS_PARQUET comes from fetch_financials.py. Every `every`-th trading
day, each stock's latest report *announced on or before that day* is used;
entry is still the next day's close, so nothing unannounced is traded on.
Reports whose period ended more than 15 months earlier are stale and dropped.

Market cap = total shares at the period end x the raw close, carried to the
signal day with the adjustment factor (adjusted / raw close) so bonus shares
and splits after the period end do not halve it.

Windows (TOP / BOTTOM = top / bottom decile of that day's ranking, else ""):

    ep    trailing-twelve-month net profit / market cap   (cheap = TOP)
    bp    book equity / market cap                         (cheap = TOP)
    roe   trailing-twelve-month net profit / book equity   (book > 0 only)
    sue   single-quarter net profit minus the same quarter a year earlier,
          / market cap. Ranked only among stocks whose report was announced
          since the previous signal day: top / bottom 20% of those. Every
          stock with a usable report is still written, as the baseline.

Then:

    python out_of_sample.py OUT_DIR VIPDOC --prices ADJUSTED_PARQUET \
        --long TOP --short BOTTOM --claims fundamental_claims.json
"""
import argparse
import os

import numpy as np
import pandas as pd

import engine as E


def raw_closes(vipdoc):
    aliases = E.bj_aliases(vipdoc)
    parts = []
    for area in ("sh", "sz", "bj"):
        for code, path in E.stock_files(vipdoc, area):
            if not E.is_a_share(code) or code in aliases:
                continue
            d, c = E.read_day_file(path)
            parts.append(pd.DataFrame({"stock": code, "date": d.astype("int32"), "raw": c}))
    return pd.concat(parts, ignore_index=True), aliases


def prev_period(period, years=0, quarters=0):
    """Report period `years` years and `quarters` quarters earlier."""
    y, md = divmod(period, 10000)
    q = {331: 1, 630: 2, 930: 3, 1231: 4}[md] - quarters
    y -= years
    while q <= 0:
        q += 4; y -= 1
    return y * 10000 + {1: 331, 2: 630, 3: 930, 4: 1231}[q]


def derive(fin):
    """TTM profit, book and the single-quarter surprise per (stock, period)."""
    fin = fin[(fin["ann"] >= fin["period"]) & (fin["shares"] > 0)].copy()
    fin = fin.drop_duplicates(["stock", "period"], keep="last")
    key = fin.set_index(["stock", "period"])

    def look(periods, col):
        idx = pd.MultiIndex.from_arrays([fin["stock"].to_numpy(), periods])
        return key[col].reindex(idx).to_numpy()

    per = fin["period"].to_numpy()
    md = per % 10000
    last_annual = np.array([p // 10000 * 10000 - 10000 + 1231 for p in per])
    year_ago = np.array([prev_period(p, years=1) for p in per])
    np_ = fin["np"].to_numpy()
    fin["ttm"] = np.where(md == 1231, np_,
                          np_ + look(last_annual, "np") - look(year_ago, "np"))

    def single_quarter(periods):
        cur = look(periods, "np") if periods is not per else np_
        prev = look(np.array([prev_period(p, quarters=1) for p in periods]), "np")
        return np.where(periods % 10000 == 331, cur, cur - prev)

    fin["sq_change"] = single_quarter(per) - single_quarter(year_ago)
    fin["book"] = fin["bvps"] * fin["shares"]
    return fin[["stock", "period", "ann", "shares", "ttm", "book", "sq_change"]]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("financials"); p.add_argument("prices"); p.add_argument("vipdoc")
    p.add_argument("out")
    p.add_argument("--start", type=int, default=20120101)
    p.add_argument("--every", type=int, default=5)
    a = p.parse_args()

    adj = pd.read_parquet(a.prices, columns=["stock", "date", "close"])
    raw, aliases = raw_closes(a.vipdoc)
    px = adj.merge(raw, on=["stock", "date"], how="inner")
    px["factor"] = px["close"] / px["raw"]
    px = px.sort_values(["stock", "date"]).reset_index(drop=True)

    fin = pd.read_parquet(a.financials)
    fin["stock"] = fin["stock"].replace(aliases)
    fin = derive(fin)

    # Adjustment factor at each period end (last trading day on or before it).
    pe = fin[["stock", "period"]].rename(columns={"period": "date"}).sort_values("date")
    pe = pd.merge_asof(pe, px[["stock", "date", "factor"]].sort_values("date"),
                       on="date", by="stock", direction="backward")
    fin = fin.merge(pe.rename(columns={"date": "period", "factor": "f_period"}),
                    on=["stock", "period"], how="left")

    dates = np.sort(px["date"].unique())
    reb = dates[dates >= a.start][:: a.every]
    prev_reb = dict(zip(reb[1:], reb[:-1]))
    prev_reb[reb[0]] = dates[np.searchsorted(dates, reb[0]) - a.every] \
        if np.searchsorted(dates, reb[0]) >= a.every else 0

    d = px[px["date"].isin(reb)].sort_values("date")
    rep = fin.sort_values(["ann", "period"])
    d = pd.merge_asof(d, rep.rename(columns={"ann": "date_ann"}), left_on="date",
                      right_on="date_ann", by="stock", direction="backward")
    stale = d["date"] // 10000 * 12 + d["date"] // 100 % 100 \
        - (d["period"] // 10000 * 12 + d["period"] // 100 % 100) > 15
    d = d[d["period"].notna() & ~stale & d["f_period"].notna()].copy()
    d["mcap"] = d["shares"] * d["raw"] * d["factor"] / d["f_period"]

    d["ep"] = d["ttm"] / d["mcap"]
    d["bp"] = d["book"] / d["mcap"]
    d["roe"] = np.where(d["book"] > 0, d["ttm"] / d["book"], np.nan)
    d["sue"] = d["sq_change"] / d["mcap"]
    fresh = d["date_ann"] > d["date"].map(prev_reb)

    parts = []
    for w in ("ep", "bp", "roe"):
        x = d[d[w].notna()]
        r = x.groupby("date")[w].rank(pct=True)
        sig = np.where(r > 0.9, "TOP", np.where(r <= 0.1, "BOTTOM", ""))
        parts.append(pd.DataFrame({"stock": x["stock"].values, "date": x["date"].values,
                                   "window": w, "signal": sig}))
    base = d[d["ep"].notna()]
    ranked = base[fresh.loc[base.index] & base["sue"].notna()]
    r = ranked.groupby("date")["sue"].rank(pct=True)
    sig = pd.Series("", index=base.index, dtype=object)
    sig.loc[ranked.index] = np.where(r > 0.8, "TOP", np.where(r <= 0.2, "BOTTOM", ""))
    parts.append(pd.DataFrame({"stock": base["stock"].values, "date": base["date"].values,
                               "window": "sue", "signal": sig.values}))

    out = pd.concat(parts, ignore_index=True)
    out["date"] = out["date"].astype("int32")
    os.makedirs(a.out, exist_ok=True)
    out.to_parquet(os.path.join(a.out, "signals.parquet"), index=False)
    print(out.groupby(["window", "signal"]).size().to_dict(),
          f"{out.stock.nunique()} stocks, {out.date.nunique()} dates")


if __name__ == "__main__":
    main()
