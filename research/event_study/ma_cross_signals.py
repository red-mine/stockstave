"""Moving-average crossover signals (均线金叉/死叉) for the event study.

    python ma_cross_signals.py ADJUSTED_PARQUET OUT_DIR --short 5 --long 20
        [--start 20120101]

For every A-share trading day with both averages defined (adjusted closes,
so an ex-rights drop does not fake a cross), the signal is

    GOLD   the short average closed above the long one today, at or below yesterday
    DEATH  the short average closed below the long one today, at or above yesterday
    ABOVE  short above long, no cross today
    BELOW  short at or below long, no cross today

Each signal is its own family. Every stock-day is written: they are the
baseline. Window name: ma{short}_{long}. Then, for example:

    python out_of_sample.py OUT_DIR VIPDOC --prices ADJUSTED_PARQUET \
        --long GOLD --short DEATH --claims ma_cross_claims.json
"""
import argparse
import os

import numpy as np
import pandas as pd


def main():
    p = argparse.ArgumentParser()
    p.add_argument("prices"); p.add_argument("out")
    p.add_argument("--short", type=int, required=True)
    p.add_argument("--long", type=int, required=True)
    p.add_argument("--start", type=int, default=20120101)
    a = p.parse_args()

    prices = pd.read_parquet(a.prices, columns=["stock", "date", "close"])
    prices = prices.sort_values(["stock", "date"]).reset_index(drop=True)
    g = prices.groupby("stock", sort=False)["close"]
    fast = g.transform(lambda s: s.rolling(a.short).mean())
    slow = g.transform(lambda s: s.rolling(a.long).mean())
    above = (fast > slow).to_numpy()
    valid = (fast.notna() & slow.notna()).to_numpy()
    same_stock = (prices["stock"] == prices["stock"].shift(1)).to_numpy()
    prev_above = np.r_[False, above[:-1]]
    prev_valid = np.r_[False, valid[:-1]] & same_stock

    signal = np.where(above, "ABOVE", "BELOW").astype(object)
    signal[valid & prev_valid & above & ~prev_above] = "GOLD"
    signal[valid & prev_valid & ~above & prev_above] = "DEATH"

    keep = valid & prev_valid & (prices["date"].to_numpy() >= a.start)
    out = pd.DataFrame({"stock": prices["stock"].to_numpy()[keep],
                        "date": prices["date"].to_numpy()[keep].astype("int32"),
                        "window": f"ma{a.short}_{a.long}",
                        "signal": signal[keep]})
    os.makedirs(a.out, exist_ok=True)
    out.to_parquet(os.path.join(a.out, "signals.parquet"), index=False)
    print(out.groupby("signal").size().to_dict(),
          f"{out.stock.nunique()} stocks, {out.date.nunique()} dates")


if __name__ == "__main__":
    main()
