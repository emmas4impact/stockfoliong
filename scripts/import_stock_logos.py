"""Audit: python -m scripts.import_stock_logos. Import reviewed PNGs: append --apply."""

import argparse
import json
from pathlib import Path

from sqlalchemy import select

from backend.app.database import SessionLocal
from backend.app.models import Stock, StockLogo

ROOT = Path(__file__).resolve().parents[1]
REVIEWED = ROOT / "backend/data/stock_logos"
BUNDLED = ROOT / "flutter_app/assets/company_logos"


def reviewed_logos():
    logos = {path.stem: (path, "Stockfolio curated asset") for path in BUNDLED.glob("*.png")}
    for ticker, source in json.loads((REVIEWED / "sources.json").read_text()).items():
        logos[ticker] = (REVIEWED / f"{ticker}.png", source)
    return logos


def audit(db, logos, apply=False):
    existing = set(db.scalars(select(StockLogo.symbol)))
    stocks = set(db.scalars(select(Stock.symbol)))
    ready = sorted((stocks - existing) & logos.keys())
    missing = sorted(stocks - existing - logos.keys())
    if apply:
        for ticker in ready:
            path, source = logos[ticker]
            data = path.read_bytes()
            if len(data) > 1024 * 1024 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError(f"Invalid reviewed PNG: {ticker}")
            db.add(StockLogo(symbol=ticker, png=data, source=source))
        db.commit()
    return ready, missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Insert missing reviewed logos; never overwrite.")
    args = parser.parse_args()
    with SessionLocal() as db:
        ready, missing = audit(db, reviewed_logos(), args.apply)
    print("Imported:" if args.apply else "Ready to import:", ", ".join(ready) or "none")
    print("Need reviewed artwork:", ", ".join(missing) or "none")


if __name__ == "__main__":
    main()
