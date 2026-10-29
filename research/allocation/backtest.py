"""Index-fund allocations on A-share ETFs, rebalanced once a year.

    python backtest.py VIPDOC [--cost 0.0005]

Uses the funds an ordinary investor can buy, so management fees and ETF
tracking are already in the prices; dividends and splits come from the TDX
ex-rights records (pytdx), the same adjustment as the event study. TDX stores
fund prices at 1/1000 yuan, ten times finer than stocks.

Part 1, ETFs from 2014-01-15 (the S&P 500 ETF's first day) to the last day:
lump sum and monthly saving, per portfolio. Part 2, indices from 2005 for the
2008 crash: CSI 300 *price* index (dividends excluded, so equity is
understated by roughly 2% a year) and the SSE treasury index.
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd
from pytdx.config.hosts import hq_hosts
from pytdx.hq import TdxHq_API

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "event_study"))
import engine as E                                     # noqa: E402
from fetch_xdxr import adjust, events_for              # noqa: E402

ETFS = {"hs300": "sh510300", "zz500": "sh510500", "sp500": "sh513500",
        "bond": "sh511010", "cash": "sh511880"}
NAMES = {"hs300": "沪深300ETF", "zz500": "中证500ETF", "sp500": "标普500ETF",
         "bond": "国债ETF", "cash": "货币ETF"}
PORTFOLIOS = {
    "全仓沪深300": {"hs300": 1.0},
    "股60债40（沪深300+国债）": {"hs300": 0.6, "bond": 0.4},
    "股60债40（分散：300/500/标普）": {"hs300": 0.3, "zz500": 0.15, "sp500": 0.15, "bond": 0.4},
    "股30债70（分散）": {"hs300": 0.15, "zz500": 0.075, "sp500": 0.075, "bond": 0.7},
    "全仓国债": {"bond": 1.0},
    "全仓货币": {"cash": 1.0},
}


def connect():
    for _, ip, port in hq_hosts:
        api = TdxHq_API(raise_exception=False)
        try:
            if api.connect(ip, port, time_out=5) and api.get_xdxr_info(1, "600000"):
                return api
        except Exception:
            pass
    raise SystemExit("no TDX server reachable")


def etf_prices(vipdoc):
    api = connect()
    cols = {}
    for key, code in ETFS.items():
        while True:          # replies can arrive out of order: accept two that agree
            first, second = events_for(api, code), events_for(api, code)
            if first is not None and first == second:
                break
            api.disconnect()
            api = connect()
        events = [dict(t) for t in {tuple(sorted(e.items())) for e in first}]  # TDX repeats some
        d, c = E.read_day_file(os.path.join(vipdoc, code[:2], "lday", code + ".day"))
        cols[key] = pd.Series(adjust(d, c / 10, events), index=d)
    api.disconnect()
    return pd.DataFrame(cols)


def index_prices(vipdoc):
    cols = {}
    for key, code in {"hs300": "sh000300", "bond": "sh000012"}.items():
        d, c = E.read_day_file(os.path.join(vipdoc, "sh", "lday", code + ".day"))
        cols[key] = pd.Series(c, index=d)
    return pd.DataFrame(cols)


def simulate(px, weights, cost, monthly=0.0, initial=1.0):
    """Daily portfolio value; rebalanced to `weights` on the first trading
    day of each year; `monthly` added on the first trading day of each month,
    invested at the target weights. Rebalancing pays `cost` on what is traded."""
    keys = list(weights)
    p = px[keys].to_numpy()
    w = np.array([weights[k] for k in keys])
    dates = px.index.to_numpy()
    units = initial * w / p[0]
    paid = initial
    value = np.empty(len(dates))
    for i in range(len(dates)):
        if i:
            new_month = dates[i] // 100 != dates[i - 1] // 100
            if new_month and monthly:
                units += monthly * w / p[i]
                paid += monthly
            if dates[i] // 10000 != dates[i - 1] // 10000:
                total = units @ p[i]
                target = total * w / p[i]
                traded = np.abs(target - units) @ p[i]
                units = target * (1 - cost * traded / total)
        value[i] = units @ p[i]
    return pd.Series(value, index=dates), paid


def stats(v):
    days = len(v)
    years = days / 244
    ret = (v.iloc[-1] / v.iloc[0]) ** (1 / years) - 1
    peak = v.cummax()
    dd = v / peak - 1
    trough = dd.idxmin()
    after = v.loc[trough:]
    rec = after[after >= peak.loc[trough]]
    recover = "未回本" if rec.empty else f"{(pd.to_datetime(str(rec.index[0])) - pd.to_datetime(str(peak.loc[:trough].idxmax()))).days / 365:.1f} 年"
    yearly = v.groupby(v.index // 10000).last()
    first = v.groupby(v.index // 10000).first().iloc[0]
    yr = yearly.pct_change()
    yr.iloc[0] = yearly.iloc[0] / first - 1
    vol = np.log(v).diff().std() * np.sqrt(244)
    return dict(ret=ret, vol=vol, mdd=dd.min(), worst=yr.min(), worst_year=int(yr.idxmin()),
                up=(yr > 0).sum(), n=len(yr), recover=recover)


def irr(contrib_dates, amounts, end_date, end_value):
    t = np.array([(pd.to_datetime(str(end_date)) - pd.to_datetime(str(d))).days / 365.25
                  for d in contrib_dates])
    lo, hi = -0.5, 0.5
    for _ in range(100):
        r = (lo + hi) / 2
        if (np.array(amounts) * (1 + r) ** t).sum() > end_value:
            hi = r
        else:
            lo = r
    return r


def report(px, title, cost, monthly=True):
    print(f"\n== {title}: {px.index[0]} .. {px.index[-1]} ==")
    print(f"{'组合':<28}{'年化':>7}{'波动':>7}{'最大回撤':>9}{'最差年份':>14}{'上涨年数':>9}  回本用时")
    for name, w in PORTFOLIOS.items():
        if not set(w) <= set(px.columns):
            continue
        v, _ = simulate(px, w, cost)
        s = stats(v)
        print(f"{name:<24}{s['ret']:>+8.1%}{s['vol']:>8.1%}{s['mdd']:>9.1%}"
              f"{s['worst']:>+9.1%} ({s['worst_year']}){s['up']:>5}/{s['n']}  {s['recover']}")
    if not monthly:
        return
    print("\n每月定投 1000 元（第一天也投 1000）:")
    months = [px.index[0]] + [d for prev, d in zip(px.index[:-1], px.index[1:]) if d // 100 != prev // 100]
    for name, w in PORTFOLIOS.items():
        if not set(w) <= set(px.columns):
            continue
        v, paid = simulate(px, w, cost, monthly=1000, initial=1000)
        r = irr(months, [1000] * len(months), px.index[-1], v.iloc[-1])
        print(f"{name:<24}投入 {paid:>9,.0f}  期末 {v.iloc[-1]:>9,.0f}  年化 {r:+.1%}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("vipdoc")
    p.add_argument("--cost", type=float, default=0.0005)
    a = p.parse_args()

    etf = etf_prices(a.vipdoc).dropna()
    report(etf, "ETF（可直接买到，费用已扣）", a.cost)
    idx = index_prices(a.vipdoc).dropna()
    report(idx[idx.index >= 20050104], "指数（沪深300不含分红，低估约2%/年）", a.cost, monthly=False)


if __name__ == "__main__":
    main()
