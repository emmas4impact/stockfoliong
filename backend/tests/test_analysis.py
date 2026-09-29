import os
import unittest
from datetime import datetime, timedelta, timezone

# Tests never connect to the application's configured database.
os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "test-only-not-a-deployment-secret"

from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import Session

from backend.app.database import Base
from backend.app.models import FundamentalObservation, Stock, StockAnalysis
from backend.app.analysis import archive_sync_analysis, latest_observations, record_observation, score_observation


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine("sqlite://")
        Base.metadata.create_all(self.engine, tables=[Stock.__table__, FundamentalObservation.__table__, StockAnalysis.__table__])
        self.db = Session(self.engine)
        self.now = datetime.now(timezone.utc)

    def tearDown(self):
        self.db.close()
        self.engine.dispose()

    def add(self, symbol, pe, sector="banking", age=0, source="ngxpulse"):
        if self.db.get(Stock, symbol) is None:
            self.db.add(Stock(symbol=symbol))
            self.db.flush()
        record_observation(self.db, {"symbol": symbol, "last_price": 20, "pe_ratio": pe,
                                    "sector": sector, "source": source}, self.now - timedelta(days=age))

    def result(self, symbol="ABC"):
        rows = latest_observations(self.db)
        return score_observation(next(row for row in rows if row.stock_symbol == symbol), rows, self.now)

    def test_comparison_excludes_wrong_sector_source_and_stale_peers(self):
        for symbol, pe in [("ABC", 10), ("B", 5), ("C", 10), ("D", 20)]:
            self.add(symbol, pe)
        self.add("OTHER", 100, sector="energy")
        self.add("STALE", 100, age=8)
        self.add("SOURCE", 100, source="ngx_doclib")
        result = self.result()
        self.assertEqual(result["peer_count"], 3)
        self.assertEqual(result["sector_pe_median"], 10)
        self.assertEqual(result["scores"]["valuation"], 50)
        self.assertIsNone(result["scores"]["overall"])

    def test_missing_negative_and_stale_target_are_not_scored(self):
        for symbol in ["B", "C", "D"]:
            self.add(symbol, 10)
        for symbol, pe, age in [("MISSING", None, 0), ("NEGATIVE", -5, 0), ("OLD", 5, 8)]:
            self.add(symbol, pe, age=age)
            self.assertIsNone(self.result(symbol)["scores"]["valuation"])

    def test_small_peer_group_withholds_score(self):
        self.add("ABC", 5)
        self.add("B", 10)
        self.assertIsNone(self.result()["scores"]["valuation"])

    def test_observations_preserve_missing_data_and_daily_history(self):
        self.add("ABC", 5)
        self.add("ABC", 5)
        self.assertEqual(self.db.scalar(select(func.count()).select_from(FundamentalObservation)), 1)
        self.add("ABC", None)
        self.assertIsNone(latest_observations(self.db)[0].inputs["pe_ratio"])
        self.add("ABC", 5)
        self.assertEqual(latest_observations(self.db)[0].inputs["pe_ratio"], 5)
        self.now += timedelta(days=1)
        self.add("ABC", 5)
        self.assertEqual(self.db.scalar(select(func.count()).select_from(FundamentalObservation)), 4)

    def test_analysis_archive_is_reproducible_and_idempotent(self):
        for symbol, pe in [("ABC", 5), ("B", 10), ("C", 15), ("D", 20)]:
            self.add(symbol, pe)
        archive_sync_analysis(self.db)
        self.db.commit()
        archive_sync_analysis(self.db)
        self.assertEqual(self.db.scalar(select(func.count()).select_from(StockAnalysis)), 4)
        saved = self.db.scalar(select(StockAnalysis).where(StockAnalysis.stock_symbol == "ABC"))
        self.assertEqual(saved.result["scores"]["valuation"], 100)
        self.assertEqual(len(saved.result["peer_inputs"]), 3)
        self.assertEqual(saved.model_version, "sector-pe-v1")


if __name__ == "__main__":
    unittest.main()
