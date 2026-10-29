"""Low-volatility signals (低波动选股) for the event study.

    python low_vol_signals.py ADJUSTED_PARQUET OUT_DIR
        [--start 20120101] [--lookback 20 60] [--every 5]

Every `every`-th trading day, each A share with a full `lookback` of daily
adjusted returns (up to and including that day's close) is ranked by their
standard deviation. The calmest decile reads LOW, the most volatile HIGH,
the rest "". One window per lookback, named vol{lookback}. Every ranked
stock-day is written: those rows are the baseline. Then:

    python out_of_sample.py OUT_DIR VIPDOC --prices ADJUSTED_PARQUET \
        --long LOW --short HIGH --claims low_vol_claims.json
"""
import argparse
import os

import numpy as np
import pandas as pd


def main():
    p = argparse.ArgumentParser()
    p.add_argument("prices"); p.add_argument("out")
    p.add_argument("--start", type=int, default=20120101)
    p.add_argument("--lookback", type=int, nargs="+", default=[20, 60])
    p.add_argument("--every", type=int, default=5, help="rank every N-th trading day")
    a = p.parse_args()

    prices = pd.read_parquet(a.prices, columns=["stock", "date", "close"])
    prices = prices.sort_values(["stock", "date"]).reset_index(drop=True)
    ret = prices.groupby("stock", sort=False)["close"].pct_change()

    dates = np.sort(prices["date"].unique())
    rebalance = dates[dates >= a.start][:: a.every]
    on_day = prices["date"].isin(rebalance).to_numpy()

    parts = []
    for n in a.lookback:
        vol = ret.groupby(prices["stock"], sort=False).transform(
            lambda s: s.rolling(n, min_periods=n).std())
        keep = on_day & vol.notna().to_numpy()
        d = pd.DataFrame({"stock": prices["stock"].to_numpy()[keep],
                          "date": prices["date"].to_numpy()[keep].astype("int32"),
                          "vol": vol.to_numpy()[keep]})
        rank = d.groupby("date")["vol"].rank(pct=True)
        d["signal"] = np.where(rank <= 0.1, "LOW", np.where(rank > 0.9, "HIGH", ""))
        d["window"] = f"vol{n}"
        parts.append(d[["stock", "date", "window", "signal"]])
    out = pd.concat(parts, ignore_index=True)

    os.makedirs(a.out, exist_ok=True)
    out.to_parquet(os.path.join(a.out, "signals.parquet"), index=False)
    print(out.groupby(["window", "signal"]).size().to_dict(),
          f"{out.stock.nunique()} stocks, {out.date.nunique()} dates")


if __name__ == "__main__":
    main()
