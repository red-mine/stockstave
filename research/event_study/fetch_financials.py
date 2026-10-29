"""Quarterly financial reports from the TDX servers, with announcement dates.

    python fetch_financials.py OUT_DIR [--beg 20091231] [--end 20260930]

Needs pytdx. TDX publishes one file per report period (gpcwYYYYMMDD.zip,
every A share's figures for that quarter-end). Files are cached under
OUT_DIR/cw/ (re-runs skip them). Writes OUT_DIR/financials.parquet, one row
per (stock, report period):

    stock      sz000001 / sh600000 / bj920001
    period     report period end, yyyymmdd (0331, 0630, 0930, 1231)
    ann        announcement date, yyyymmdd (TDX field 314)
    eps        basic earnings per share, year to date (field 1)
    bvps       net assets per share (field 4)
    np         net profit attributable to the parent, year to date (field 96)
    shares     total shares (field 238)

Figures are year to date: a Q3 report holds nine months of profit. The
field numbers were checked against published reports (see docs/fundamentals.md).
"""
import argparse
import os

import pandas as pd
from pytdx.crawler.history_financial_crawler import (HistoryFinancialCrawler,
                                                      HistoryFinancialListCrawler)

FIELDS = {"eps": 1, "bvps": 4, "np": 96, "shares": 238, "ann": 314}


def stock_code(code):
    if code.startswith(("60", "68")):
        return "sh" + code
    if code.startswith(("00", "30")):
        return "sz" + code
    if code.startswith(("43", "83", "87", "88", "92")):
        return "bj" + code
    return None                                 # B shares, funds, indices


def yymmdd(x):
    x = int(round(x))
    if x <= 0:
        return 0
    return (19000000 if x // 10000 >= 90 else 20000000) + x


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--beg", type=int, default=20091231)
    p.add_argument("--end", type=int, default=20260930)
    a = p.parse_args()

    cw = os.path.join(a.out, "cw")
    os.makedirs(cw, exist_ok=True)
    listing = HistoryFinancialListCrawler().fetch_and_parse()
    files = sorted((f for f in listing
                    if a.beg <= int(f["filename"][4:12]) <= a.end), key=lambda f: f["filename"])

    parts = []
    for f in files:
        name = f["filename"]
        path = os.path.join(cw, name)
        c = HistoryFinancialCrawler()
        if os.path.exists(path) and os.path.getsize(path) == f["filesize"]:
            with open(path, "rb") as fh:
                data = c.parse(fh)
        else:
            data = c.fetch_and_parse(filename=name, filesize=f["filesize"], path_to_download=path)
        df = c.to_df(data).reset_index()
        out = pd.DataFrame({"stock": df["code"].map(stock_code),
                            "period": df["report_date"].astype("int32")})
        for k, col in FIELDS.items():
            out[k] = df[f"col{col}"].astype("float64")
        out["ann"] = out["ann"].map(yymmdd).astype("int32")
        out = out[out["stock"].notna()]
        parts.append(out)
        print(name, len(out), "stocks", flush=True)

    res = pd.concat(parts, ignore_index=True)
    res.to_parquet(os.path.join(a.out, "financials.parquet"), index=False)
    print(len(res), "rows,", res.stock.nunique(), "stocks")


if __name__ == "__main__":
    main()
