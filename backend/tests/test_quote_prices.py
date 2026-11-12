import os
import unittest
from types import SimpleNamespace

os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "test-only-not-a-deployment-secret"

from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from backend.app.database import Base
from backend.app.models import Stock, StockPrice
from backend.app.ngx_client import normalize_stock
from backend.app.services import holding_to_dict, upsert_daily_stock_snapshot, upsert_stock


class QuotePriceTests(unittest.TestCase):
    def test_dangcem_kobo_equities_record(self):
        raw = {
            "symbol": "DANGCEM", "name": "Dangote Cement Plc",
            "current_price": 1469.9, "previous_close": 1469.9,
            "change_percent": 0, "official_change_percent": None, "pct_change_7d": -1.35,
            "open_price": 1469.9, "high_price": None, "low_price": None,
            "value": 7257978, "trades": 91, "volume": 5486,
            "market_cap": 24802444743044.902, "shares_outstanding": 16873559251,
            "sector": "INDUSTRIAL GOODS", "market": "Premium Board",
            "trade_date": "2026-11-12T00:00:00",
        }
        quote = normalize_stock(raw, "ngxpulse")
        for field in ("symbol", "name", "previous_close", "open_price", "high_price",
                      "low_price", "volume", "market_cap", "shares_outstanding", "sector"):
            with self.subTest(field=field):
                self.assertEqual(quote[field], raw[field])
        self.assertEqual(quote["last_price"], 1469.9)
        self.assertEqual(quote["change"], 0)
        self.assertEqual(quote["percent_change"], 0)

    def test_corrected_quote_repairs_existing_holding_and_daily_snapshot(self):
        engine = create_engine("sqlite://")
        self.addCleanup(engine.dispose)
        Base.metadata.create_all(engine, tables=[Stock.__table__, StockPrice.__table__])
        with Session(engine) as db:
            turnover = 158940297.10
            bad = upsert_stock(db, {"symbol": "ACCESSCORP", "last_price": turnover,
                                    "open_price": turnover, "source": "ngxpulse"})
            upsert_daily_stock_snapshot(db, bad)
            # Illustrative unit prices; turnover is the implied price in the report.
            raw = {"symbol": "ACCESSCORP", "value": turnover, "current_price": "33.00",
                   "previous_close": 32, "shares_outstanding": 1000}
            quote = normalize_stock(raw, "ngxpulse")
            stock = upsert_stock(db, quote)
            upsert_daily_stock_snapshot(db, stock)
            daily = db.query(StockPrice).one()
            self.assertEqual(float(daily.close_price), 33)
            self.assertEqual(float(daily.open_price), 32)
            self.assertEqual(quote["change"], 1)
            self.assertEqual(quote["percent_change"], 3.125)
            self.assertEqual(quote["market_cap"], 33000)
            row = holding_to_dict(SimpleNamespace(stock=stock, stock_symbol=stock.symbol,
                                  quantity=166350, avg_purchase_price=22, notes=None))
            self.assertEqual(row["total_value"], 5489550)
            self.assertEqual(row["total_cost"], 3659700)
            self.assertEqual(row["profit_loss_percent"], 50)
            # No previous close or opening price in the next quote: don't keep
            # the old baseline and report that as today's move.
            stock = upsert_stock(db, normalize_stock({"symbol": stock.symbol, "price": 34}, "ngxpulse"))
            self.assertIsNone(stock.open_price)
            self.assertIsNone(stock.percent_change)

    def test_turnover_is_never_a_kobo_quote_even_when_price_is_missing(self):
        for invalid in (None, "", "NaN", "inf", True, 0, -1):
            with self.subTest(invalid=invalid):
                raw = {"symbol": "CHAMS", "current_price": invalid, "Value": 2074723.86}
                self.assertIsNone(normalize_stock(raw, "ngxpulse"))
                raw["close_price"] = 4.2
                self.assertEqual(normalize_stock(raw, "ngxpulse")["last_price"], 4.2)

    def test_doclib_ticker_value_remains_a_unit_price(self):
        quote = normalize_stock({"SYMBOL": "CUTIX", "Value": "3.00", "PercChange": "2"},
                                "ngx_doclib")
        self.assertEqual(quote["last_price"], 3)
        self.assertEqual(quote["percent_change"], 2)
