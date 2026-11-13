import os
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "test-only-not-a-deployment-secret"

from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from backend.app import ngx_client, services
from backend.app.database import Base
from backend.app.financials import get_financials
from backend.app.models import Stock, StockAnalysis, SyncLog


class KoboSyncTests(unittest.TestCase):
    def setUp(self):
        engine = create_engine("sqlite://")
        Base.metadata.create_all(engine)
        self.db = Session(engine)
        self.addCleanup(engine.dispose)
        self.addCleanup(self.db.close)
        quotes = [{"symbol": s, "sector": "Financial Services", "source": "ngxpulse",
                   "pe_ratio": 8 if s == "UNMATCHED" else None, "last_price": 119.84}
                  for s in ["GTCO", "BANK1", "BANK2", "BANK3", "UNMATCHED", "FORWARD"]]
        def mock(target, **kwargs):
            p = patch(target, **kwargs)
            self.addCleanup(p.stop)
            return p.start()
        mock("backend.app.services.fetch_all_stocks_from_ngx", return_value=quotes)
        mock("backend.app.services.get_settings").return_value.ngxpulse_enabled = True
        mock("backend.app.services.fetch_market_snapshot_from_ngx", return_value={})
        mock("backend.app.services.refresh_market_status")
        mock("backend.app.ngx_client._ngxpulse_headers", return_value={"X-API-Key": "test"})
        self.get = mock("backend.app.ngx_client._get_session").return_value.get
        self.get.return_value.status_code = 200

    def test_bulk_join_and_saved_sector_score(self):
        rows = [{"symbol": " gtco ", "pe_ratio": 5.6, "eps": 21.39, "forward_pe": 4.73,
                 "pb_ratio": 1.26, "updated_at": "2026-11-08T05:02:25.76+00:00",
                 "extra": {"book_value_per_share": 94.45}},
                {"symbol": "FORWARD", "forward_pe": 3.1, "pe_ratio": None},
                {"symbol": "BANK3", "pe_ratio": -2}, {"symbol": "BANK2", "pe_ratio": 7},
                {"symbol": "BANK1", "pe_ratio": 6}]
        self.get.return_value.json.return_value = {"success": True, "count": len(rows), "fundamentals": rows}
        result = services.sync_stocks(self.db)
        self.assertIn("5/6", result[-1])
        self.get.assert_called_once_with("https://koboterminal.com/api/ngxdata/fundamentals",
                                         headers={"X-API-Key": "test"}, timeout=20, allow_redirects=False)
        results = {r.stock_symbol: r.result for r in self.db.scalars(select(StockAnalysis))}
        gtco = results["GTCO"]
        self.assertEqual(gtco["inputs"]["pe_ratio"], 5.6)
        self.assertEqual(gtco["inputs"]["pe_basis"], "trailing")
        self.assertEqual(gtco["inputs"]["fundamentals"]["pb_ratio"], 1.26)
        self.assertEqual(gtco["inputs"]["fundamentals"]["extra"], rows[0]["extra"])
        self.assertEqual(gtco["inputs"]["fundamentals"]["updated_at"], rows[0]["updated_at"])
        self.assertEqual(gtco["scores"]["valuation"], 100)
        self.assertIsNone(results["FORWARD"]["inputs"]["pe_ratio"])
        self.assertIsNone(results["BANK3"]["scores"]["valuation"])
        self.assertEqual(results["UNMATCHED"]["inputs"]["pe_ratio"], 8)

    def test_denied_fundamentals_does_not_abort_stock_sync(self):
        self.get.return_value.status_code = 403
        result = services.sync_stocks(self.db)
        self.assertEqual(result[3], "success")
        self.assertIn("403", result[4])
        self.assertEqual(float(self.db.get(Stock, "GTCO").last_price), 119.84)
        warning = self.db.scalar(select(SyncLog).where(SyncLog.source == "kobo_fundamentals"))
        self.assertEqual(warning.status, "warning")

    def test_rejects_invalid_envelope(self):
        self.get.return_value.json.return_value = {"success": False, "fundamentals": []}
        with self.assertRaises(ngx_client.NgxFetchError):
            ngx_client.fetch_kobo_fundamentals()

    def test_quota_failure_keeps_committed_snapshot_and_receipt_time(self):
        self.get.return_value.json.return_value = {"success": True, "fundamentals": [
            {"symbol": "GTCO", "pb_ratio": 1.26, "eps": 21.39}
        ]}
        services.sync_stocks(self.db)
        original = get_financials(self.db, "GTCO").valuation
        services.sync_stocks(self.db)
        self.assertEqual(self.get.call_count, 1)
        self.assertEqual(get_financials(self.db, "GTCO").valuation, original)

        batch = services.get_cached_dict_payload(self.db, services.FUNDAMENTALS_CACHE_KEY)
        batch["received_at"] = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        services.cache_api_payload(self.db, cache_key=services.FUNDAMENTALS_CACHE_KEY, payload=batch)
        self.db.commit()
        self.get.return_value.status_code = 429
        self.assertIn("429", services.sync_stocks(self.db)[-1])
        self.assertIn("backoff", services.sync_stocks(self.db)[-1])
        with Session(self.db.get_bind()) as reader:
            self.assertEqual(get_financials(reader, "GTCO").valuation, original)
            self.assertIsNone(get_financials(reader, "UNMATCHED").valuation)
        self.assertEqual(self.get.call_count, 2)
        services.cache_api_payload(self.db, cache_key=services.FUNDAMENTALS_RETRY_KEY,
                                   payload={"retry_after": (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()})
        self.db.commit()
        self.get.return_value.status_code = 200
        self.get.return_value.json.return_value = {"success": True, "fundamentals": [
            {"symbol": "GTCO", "pb_ratio": 1.35, "eps": 22.01}
        ]}
        services.sync_stocks(self.db)
        refreshed = get_financials(self.db, "GTCO").valuation
        self.assertEqual(self.get.call_count, 3)
        self.assertEqual(refreshed.pb_ratio, 1.35)
        self.assertGreater(refreshed.observed_at, original.observed_at)
