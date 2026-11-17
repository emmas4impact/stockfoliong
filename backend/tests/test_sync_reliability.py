import os
import tempfile
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "test-only-not-a-deployment-secret"

from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import Session

from backend.app import services
from backend.app.database import Base
from backend.app.models import Stock, StockPrice, SyncLog


class SyncReliabilityTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.engine = create_engine(f"sqlite:///{Path(directory.name) / 'sync.db'}")
        self.addCleanup(self.engine.dispose)
        Base.metadata.create_all(self.engine)
        self.db = Session(self.engine, autoflush=False)
        self.addCleanup(self.db.close)
        self.db.add_all([Stock(symbol="GTCO", last_price=17), Stock(symbol="UBA", last_price=18)])
        self.db.commit()
        self.mock("get_settings", return_value=SimpleNamespace(ngxpulse_enabled=True))
        settings = patch("backend.app.models.get_settings", return_value=SimpleNamespace(ngxpulse_enabled=True))
        settings.start()
        self.addCleanup(settings.stop)
        self.quotes = self.mock("fetch_all_stocks_from_ngx", return_value=[
            {"symbol": "GTCO", "last_price": 27, "source": "ngxpulse"}])
        self.mock("_fundamentals_for_sync", return_value=({}, datetime.now(timezone.utc).isoformat()))

    def mock(self, name, **kwargs):
        p = patch.object(services, name, **kwargs)
        self.addCleanup(p.stop)
        return p.start()

    def test_prices_commit_without_history_overview_or_status_requests(self):
        history = self.mock("fetch_historical_prices_cached")
        overview = self.mock("fetch_market_snapshot_from_ngx")
        status = self.mock("refresh_market_status")
        with self.assertLogs("uvicorn.error.sync", level="INFO") as logs:
            result = services.sync_stocks(self.db, include_history=False)
        self.assertEqual(result[1:4], (1, 1, "success"))
        for call in (history, overview, status):
            call.assert_not_called()
        with Session(self.engine) as reader:
            self.assertEqual(reader.get(Stock, "GTCO").last_price, 27)
            self.assertEqual(reader.scalar(select(StockPrice)).close_price, 27)
        self.assertTrue(any("stage=commit_prices completed" in line for line in logs.output))

    def test_another_local_sync_does_not_queue_or_fetch(self):
        services._stock_sync_lock.acquire()
        try:
            result = services.sync_stocks(self.db)
        finally:
            services._stock_sync_lock.release()
        self.assertEqual(result[3:], ("warning", services.SYNC_BUSY_MESSAGE))
        self.quotes.assert_not_called()

    def test_postgres_guard_is_nonblocking_and_transaction_scoped(self):
        db = Mock()
        db.get_bind.return_value.dialect.name = "postgresql"
        db.scalar.return_value = False
        result = services.sync_stocks(db)
        self.assertEqual(result[3], "warning")
        self.assertIn("pg_try_advisory_xact_lock", str(db.scalar.call_args.args[0]))
        self.assertEqual([str(call.args[0]) for call in db.execute.call_args_list], [
            "SET LOCAL lock_timeout = '5s'", "SET LOCAL statement_timeout = '60s'"])
        db.rollback.assert_called_once()
        self.quotes.assert_not_called()

    def test_failure_rolls_back_prices_records_safe_error_and_releases_guard(self):
        with patch.object(services, "archive_sync_analysis", side_effect=RuntimeError("secret-provider-url")):
            with self.assertLogs("uvicorn.error.sync", level="ERROR") as logs:
                with self.assertRaises(services.StockSyncError) as error:
                    services.sync_stocks(self.db)
        self.assertNotIn("secret-provider-url", str(error.exception))
        self.assertTrue(any("stage=archive_analysis" in line for line in logs.output))
        with Session(self.engine) as reader:
            self.assertEqual(reader.get(Stock, "GTCO").last_price, 17)
            log = reader.scalar(select(SyncLog))
            self.assertEqual(log.status, "failed")
            self.assertNotIn("secret-provider-url", log.message)
        self.assertEqual(services.sync_stocks(self.db)[3], "success")

    def test_reference_history_is_committed_before_next_provider_call(self):
        self.mock("fetch_market_snapshot_cached", return_value={})
        self.mock("fetch_market_news_cached", return_value=[])
        self.mock("fetch_disclosure_feed", return_value=[{"symbol": "GTCO"}])
        self.mock("fetch_historical_prices_cached", return_value=[{
            "trade_date": date.today(), "close_price": 25,
            "open_price": 24, "high_price": 26, "low_price": 23, "volume": 100}])
        visited = []

        def fetch_dividends(symbol, limit):
            # A separate connection must see the write before more network I/O.
            with Session(self.engine) as reader:
                row = reader.scalar(select(StockPrice).where(StockPrice.stock_symbol == symbol))
                self.assertIsNotNone(row)
                self.assertEqual(row.close_price, 25)
                if symbol == "GTCO":
                    stock = reader.get(Stock, symbol)
                    stock.last_price = 30
                    services.upsert_daily_stock_snapshot(reader, stock)
                    reader.commit()
            self.assertFalse(self.db.in_transaction())
            visited.append(symbol)
            if symbol == "UBA":
                raise RuntimeError("interrupted late in refresh")
            return []

        self.mock("fetch_dividend_history_cached", side_effect=fetch_dividends)
        with self.assertRaises(RuntimeError):
            services.refresh_reference_caches(self.db)
        self.db.rollback()
        self.assertEqual(visited, ["GTCO", "UBA"])
        with Session(self.engine) as reader:
            self.assertEqual(len(list(reader.scalars(select(StockPrice)))), 2)
            self.assertEqual(reader.scalar(select(StockPrice).where(
                StockPrice.stock_symbol == "GTCO")).close_price, 30)
            self.assertIsNone(reader.scalar(select(SyncLog).where(
                SyncLog.source == services.REFERENCE_CACHE_SYNC_SOURCE,
                SyncLog.status == "success")))

    def test_reference_refresh_completes_and_retains_counts(self):
        self.mock("fetch_market_snapshot_cached", return_value={})
        self.mock("fetch_market_news_cached", return_value=[])
        self.mock("fetch_disclosure_feed", return_value=[{"symbol": "GTCO"}])
        self.mock("fetch_historical_prices_cached", return_value=[])
        self.mock("fetch_dividend_history_cached", return_value=[])
        self.assertEqual(services.refresh_reference_caches(self.db), (0, 5))
        self.assertFalse(services.reference_cache_refresh_due(self.db))

    def test_overview_failure_does_not_change_saved_prices(self):
        self.mock("fetch_market_snapshot_from_ngx", side_effect=services.NgxFetchError("private URL"))
        services.refresh_market_overview(self.db)
        self.assertEqual(self.db.get(Stock, "GTCO").last_price, 17)
        log = self.db.scalar(select(SyncLog))
        self.assertEqual(log.status, "warning")
        self.assertNotIn("private URL", log.message)

    def test_history_is_batched_with_last_duplicate_winning_and_no_implicit_commit(self):
        start = date(2025, 1, 1)
        rows = [{"trade_date": start + timedelta(days=i), "close_price": 25,
                 "open_price": 24, "high_price": 26, "low_price": 23, "volume": 100}
                for i in range(501)]
        rows.append({**rows[0], "close_price": 29})
        self.mock("fetch_historical_prices_cached", return_value=rows)
        writes = []

        def count_write(conn, cursor, statement, parameters, context, many):
            if statement.startswith("INSERT INTO stock_prices"):
                writes.append(statement)

        event.listen(self.engine, "before_cursor_execute", count_write)
        try:
            self.assertEqual(services.upsert_stock_history(self.db, "GTCO", None), 501)
        finally:
            event.remove(self.engine, "before_cursor_execute", count_write)
        self.assertEqual(len(writes), 3)
        self.assertEqual(self.db.scalar(select(StockPrice).where(StockPrice.trade_date == start)).close_price, 29)
        with Session(self.engine) as reader:
            self.assertIsNone(reader.scalar(select(StockPrice)))
        self.db.commit()
        with Session(self.engine) as reader:
            self.assertEqual(len(list(reader.scalars(select(StockPrice)))), 501)
        services.upsert_stock_history(self.db, "GTCO", None)
        self.db.commit()
        self.assertEqual(len(list(self.db.scalars(select(StockPrice)))), 501)

    def test_route_returns_actionable_service_error(self):
        from fastapi import HTTPException
        from backend.app import main

        with patch.object(main, "sync_stocks", side_effect=services.StockSyncError("Check sync stage logs.")):
            with self.assertRaises(HTTPException) as error:
                main.run_stock_sync(include_history=False, db=self.db, _=object())
        self.assertEqual(error.exception.status_code, 503)
        self.assertEqual(error.exception.detail, "Check sync stage logs.")
