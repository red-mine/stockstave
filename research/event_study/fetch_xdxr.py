"""Build dividend- and split-adjusted closes from TDX ex-rights records.

    python fetch_xdxr.py VIPDOC OUT_DIR [--beg 20201201] [--end 20261013]

Needs pytdx. Ex-rights/ex-dividend events (除权除息) come from the TDX quote
servers, the same source as the .day files the engine reads, so the raw
closes and the corporate actions line up. Each event's reference price is

    ref = (P * 10 - cash + rights * rights_price) / (10 + bonus + rights)

(per-10-share terms, P = last close before the ex-date), and the adjusted
series is raw close x the running product of P / ref -- a multiplicative
back-adjustment, so every daily return equals the shareholder's return.

Events are cached per stock under OUT_DIR/xdxr/ (re-runs skip finished
stocks); writes OUT_DIR/adjusted.parquet with columns stock, date, close.
"""
import argparse
import itertools
import json
import os
import queue
import threading

import numpy as np
import pandas as pd
from pytdx.config.hosts import hq_hosts
from pytdx.hq import TdxHq_API

import engine as E

MARKET = {"sz": 0, "sh": 1, "bj": 2}
EX_RIGHTS, RESIZE = 1, 11      # 除权除息, 扩缩股


def events_for(api, code):
    rows = api.get_xdxr_info(MARKET[code[:2]], code[2:])
    if rows is None:
        return None
    out = []
    for r in rows:
        if r["category"] not in (EX_RIGHTS, RESIZE):
            continue
        out.append(dict(date=r["year"] * 10000 + r["month"] * 100 + r["day"],
                        category=r["category"], cash=r["fenhong"] or 0.0,
                        bonus=r["songzhuangu"] or 0.0, rights=r["peigu"] or 0.0,
                        rights_price=r["peigujia"] or 0.0, resize=r["suogu"] or 0.0))
    return out


def adjust(dates, closes, events):
    """Raw closes x cumulative back-adjustment factor from the ex-rights events."""
    factor = np.ones(dates.size)
    pending = sorted(events, key=lambda e: e["date"])
    f = 1.0
    j = 0
    while j < len(pending) and pending[j]["date"] <= dates[0]:
        j += 1                                 # events before the series start
    for i in range(1, dates.size):
        prev = closes[i - 1]
        price = prev
        while j < len(pending) and pending[j]["date"] <= dates[i]:
            e = pending[j]
            if e["category"] == EX_RIGHTS:
                price = (price * 10 - e["cash"] + e["rights"] * e["rights_price"]) / \
                        (10 + e["bonus"] + e["rights"])
            elif e["resize"] > 0:
                price = price / e["resize"]
            j += 1
        if price != prev and price > 0:
            f *= prev / price
        factor[i] = f
    return closes * factor


def main():
    p = argparse.ArgumentParser()
    p.add_argument("vipdoc"); p.add_argument("out")
    p.add_argument("--beg", type=int, default=20201201)
    p.add_argument("--end", type=int, default=20261013)
    p.add_argument("--connections", type=int, default=4)
    a = p.parse_args()

    aliases = E.bj_aliases(a.vipdoc)
    paths = {}
    for area in ("sh", "sz", "bj"):
        for c, path in E.stock_files(a.vipdoc, area):
            if E.is_a_share(c) and c not in aliases:
                dates, _ = E.read_day_file(path)
                if dates.size and dates[-1] >= a.beg:   # skip long-delisted stocks
                    paths[c] = path
    cache = os.path.join(a.out, "xdxr")
    os.makedirs(cache, exist_ok=True)
    todo = queue.Queue()
    for c in paths:
        if not os.path.exists(os.path.join(cache, c + ".json")):
            todo.put(c)
    print(f"{len(paths)} stocks, {todo.qsize()} to fetch", flush=True)

    # cycle through the server list; a dropped connection moves to the next
    hosts = itertools.cycle([(ip, port) for _, ip, port in hq_hosts])
    hosts_lock = threading.Lock()
    failed = []

    def connect():
        while True:
            with hosts_lock:
                host = next(hosts)
            api = TdxHq_API(raise_exception=False)
            try:
                if api.connect(*host, time_out=5) and api.get_xdxr_info(1, "600000"):
                    return api
            except Exception:
                pass

    def worker():
        # pytdx answers are matched to requests only by order: after a
        # timeout, the late reply to one request is read as the reply to the
        # next, and every later stock gets its predecessor's events. So each
        # stock is asked twice in a row and accepted only when both replies
        # agree; any disagreement or error drops the connection.
        api = connect()
        while api is not None:
            try:
                code = todo.get_nowait()
            except queue.Empty:
                break
            try:
                first = events_for(api, code)
                second = events_for(api, code) if first is not None else None
            except Exception:
                first = second = None
            if first is None or first != second:
                todo.put(code)
                api.disconnect()
                api = connect()
                continue
            with open(os.path.join(cache, code + ".json"), "w") as f:
                json.dump(first, f)
        if api is not None:
            api.disconnect()

    threads = [threading.Thread(target=worker) for _ in range(a.connections)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    left = [c for c in paths if not os.path.exists(os.path.join(cache, c + ".json"))]
    if left:
        raise SystemExit(f"{len(left)} stocks without events (re-run to resume): {left[:20]}")

    frames = []
    for code, path in paths.items():
        with open(os.path.join(cache, code + ".json")) as f:
            events = json.load(f)
        dates, closes = E.read_day_file(path)
        keep = (dates >= a.beg) & (dates <= a.end) & (closes > 0)
        if not keep.any():
            continue                           # delisted before --beg
        frames.append(pd.DataFrame({"stock": code, "date": dates[keep].astype("int32"),
                                    "close": adjust(dates[keep], closes[keep], events)}))
    out = pd.concat(frames, ignore_index=True)
    out.to_parquet(os.path.join(a.out, "adjusted.parquet"), index=False)
    print(f"{out.stock.nunique()} stocks adjusted, {len(out)} rows")


if __name__ == "__main__":
    main()
