import os
import unittest
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "test-only-not-a-deployment-secret"

from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session

from backend.app import main, ngx_client, services
from backend.app.database import Base
from backend.app.models import Stock, StockPrice
from backend.app.schemas import StockDetailOut


class ChartReadTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine("sqlite://")
        self.addCleanup(self.engine.dispose)
        Base.metadata.create_all(self.engine)
        self.db = Session(self.engine, autoflush=False)
        self.addCleanup(self.db.close)
        self.db.add(Stock(symbol="GTCO", last_price=30, source="ngxpulse"))
        self.db.commit()
        self.db.add_all([StockPrice(stock_symbol="GTCO", trade_date=date.today() - timedelta(days=i),
                                    close_price=30 - i / 100) for i in range(365)])
        self.db.commit()
        provider = patch.object(ngx_client, "_get_session", side_effect=AssertionError("Provider called during chart read"))
        self.provider = provider.start()
        self.addCleanup(provider.stop)
        self.sql = []
        event.listen(self.engine, "before_cursor_execute", self.record_sql)

    def record_sql(self, conn, cursor, statement, parameters, context, many):
        self.sql.append(statement)

    def test_detail_with_empty_auxiliary_caches_is_read_only(self):
        for symbol, expected in [("GTCO", 365), ("NEW", 0)]:
            if symbol == "NEW":
                self.db.add(Stock(symbol="NEW"))
                self.db.commit()
            self.sql.clear()
            detail = main.build_stock_detail(symbol, "1y", 12, 6, self.db)
            payload = StockDetailOut.model_validate(detail).model_dump(mode="json")
            self.assertEqual(len(payload["history"]), expected)
            self.assertEqual(payload["offers"], [])
            self.assertTrue(all(query.startswith("SELECT") for query in self.sql))
        self.provider.assert_not_called()

    def test_history_limits_are_applied_in_sql_and_sorted_for_chart(self):
        rows = main.get_stock_history("gtco", "5d", 12, self.db, None)
        self.assertEqual(len(rows), 5)
        self.assertEqual([row.trade_date for row in rows], sorted(row.trade_date for row in rows))
        self.assertTrue(any("LIMIT" in query for query in self.sql))
        self.provider.assert_not_called()

    def test_saved_auxiliary_data_still_reaches_detail(self):
        self.db.get(Stock, "GTCO").ngx_id = "GTCO"
        services.cache_api_payload(self.db, cache_key=services.company_news_cache_key("GTCO", 6), payload=[{"title": "Results"}])
        services.cache_api_payload(self.db, cache_key=services.dividend_cache_key("GTCO", 10), payload=[{"amount": 1}])
        services.cache_api_payload(self.db, cache_key=services.MARKET_SNAPSHOT_CACHE_KEY, payload={"asi": 100})
        self.db.commit()
        with patch.object(main, "settings", SimpleNamespace(ngxpulse_enabled=True)):
            detail = main.build_stock_detail("GTCO", "5d", 12, 6, self.db)
        self.assertEqual(detail["news"], [{"title": "Results"}])
        self.assertEqual(detail["dividends"], [{"amount": 1}])
        self.assertEqual(detail["market_snapshot"], {"asi": 100})

    def test_cached_offers_recheck_expiry_without_network(self):
        snapshot = {"updated_at": datetime.now(timezone.utc).isoformat(), "data": [{
            "name": "GTCO", "symbol": "GTCO", "type_label": "Rights issue", "status": "open",
            "end_date": (date.today() + timedelta(days=2)).isoformat()}]}
        with patch.object(services, "fetch_offer_snapshot", return_value=snapshot):
            services.refresh_offers_cache(self.db)
        self.assertEqual(len(services.get_cached_offers(self.db)), 1)
        snapshot["updated_at"] = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
        services.cache_api_payload(self.db, cache_key=services.OFFERS_CACHE_KEY, payload=snapshot)
        self.db.commit()
        self.assertEqual(services.get_cached_offers(self.db), [])
        self.provider.assert_not_called()
