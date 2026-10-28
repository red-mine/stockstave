"""Example signal source that is not the five-line engine: 20-day momentum.

    python momentum_signals.py ADJUSTED_PARQUET OUT_DIR
        [--start 20120101] [--lookback 20] [--every 5]

Every `every`-th trading day, each A share with enough history is ranked by
its adjusted return over the last `lookback` sessions, up to and including
that day's close. The top decile reads TOP, the bottom decile BOTTOM, the
rest "". Every ranked stock-day is written, signal or not, because those rows
are the baseline the signals are measured against.

Writes OUT_DIR/signals.parquet in the format analyze.py documents. Then:

    python analyze.py OUT_DIR VIPDOC --prices ADJUSTED_PARQUET --long TOP --short BOTTOM
    python out_of_sample.py OUT_DIR VIPDOC --prices ADJUSTED_PARQUET --long TOP --short BOTTOM

A new idea needs only a script like this one; prices, returns, baselines
and statistics are shared.
"""
import argparse
import os

import numpy as np
import pandas as pd


def main():
    p = argparse.ArgumentParser()
    p.add_argument("prices"); p.add_argument("out")
    p.add_argument("--start", type=int, default=20120101)
    p.add_argument("--lookback", type=int, default=20)
    p.add_argument("--every", type=int, default=5, help="rank every N-th trading day")
    a = p.parse_args()

    prices = pd.read_parquet(a.prices).sort_values(["stock", "date"])
    g = prices.groupby("stock", sort=False)["close"]
    prices["mom"] = prices["close"] / g.shift(a.lookback) - 1

    dates = np.sort(prices["date"].unique())
    rebalance = dates[dates >= a.start][:: a.every]
    d = prices[prices["date"].isin(rebalance) & prices["mom"].notna()].copy()
    rank = d.groupby("date")["mom"].rank(pct=True)
    d["signal"] = np.where(rank > 0.9, "TOP", np.where(rank <= 0.1, "BOTTOM", ""))
    out = pd.DataFrame({"stock": d["stock"].values, "date": d["date"].astype("int32").values,
                        "window": f"mom{a.lookback}", "signal": d["signal"].values})

    os.makedirs(a.out, exist_ok=True)
    out.to_parquet(os.path.join(a.out, "signals.parquet"), index=False)
    print(out.groupby("signal").size().to_dict(),
          f"{out.stock.nunique()} stocks, {out.date.nunique()} dates")


if __name__ == "__main__":
    main()
