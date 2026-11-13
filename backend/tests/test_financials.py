import asyncio
import os
import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "test-only-not-a-deployment-secret"

import httpx
from pydantic import ValidationError
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from backend.app import main
from backend.app.auth import get_current_user
from backend.app.database import Base, get_db
from backend.app.financials import StatementInput, get_financials, statement_history, valuation_snapshot
from backend.app.models import FinancialStatement, FundamentalObservation, Stock, User


def statement(year=2025, **changes):
    values = dict(fiscal_year=year, basis="annual", period_start=f"{year}-01-01",
                  period_end=f"{year}-12-31", currency="NGN", audited=True,
                  source_url="https://doclib.ngxgroup.com/report.pdf", source_title="Annual report",
                  metrics={"revenue": 1200, "total_equity": 500, "eps": 2.4}, reviewed=True)
    values.update(changes)
    return StatementInput.model_validate(values)


class FinancialsTests(unittest.TestCase):
    def test_only_comparable_positive_baselines_have_growth(self):
        previous = statement(2024, metrics={"revenue": 1000, "total_equity": -10, "eps": 0})
        result = statement_history([previous, statement()])[0]
        self.assertEqual(result.yoy["revenue"], 20)
        self.assertIsNone(result.yoy["total_equity"])
        self.assertIsNone(result.yoy["eps"])
        self.assertEqual(result.period_key, "2025:0:annual:consolidated")
        for changed in [dict(currency="USD"), dict(scope="company"), dict(period_start="2024-06-01")]:
            self.assertIsNone(statement_history([statement(2024, **changed), statement()])[0].yoy["revenue"])

    def test_ytd_does_not_compare_to_standalone_quarter(self):
        current = statement(2025, quarter=3, basis="year_to_date", period_end="2025-09-30")
        prior = statement(2024, quarter=3, basis="standalone_quarter",
                          period_start="2024-07-01", period_end="2024-09-30")
        self.assertIsNone(statement_history([prior, current])[0].yoy["revenue"])

    def test_invalid_statement_rejected(self):
        for changes in [dict(metrics={"revenue": float("nan")}), dict(metrics={}),
                        dict(reviewed=False), dict(quarter=3), dict(source_url="javascript:alert(1)"),
                        dict(basis="standalone_quarter", quarter=3, period_end="2025-09-30"),
                        dict(period_end="2199-12-31")]:
            with self.subTest(changes=changes), self.assertRaises(ValidationError):
                statement(**changes)

    def test_provider_snapshot_freshness_and_missing_data(self):
        now = datetime.now(timezone.utc)
        def observation(metrics, observed=now):
            return SimpleNamespace(inputs={"fundamentals": metrics}, observed_at=observed)
        snapshot = valuation_snapshot(observation({"pb_ratio": .41, "eps": 4.28,
                                                   "updated_at": now.isoformat()}), now)
        self.assertEqual(snapshot.pb_ratio, .41)
        self.assertEqual(snapshot.freshness, "current")
        self.assertEqual(snapshot.period_basis, "unspecified_by_provider")
        self.assertEqual(valuation_snapshot(observation({}), now).freshness, "unknown")
        self.assertEqual(valuation_snapshot(observation({}, now - timedelta(days=8)), now).freshness, "stale")
        self.assertIsNone(valuation_snapshot(observation({"pb_ratio": "NaN"}), now).pb_ratio)
        self.assertIsNone(valuation_snapshot(SimpleNamespace(inputs={}, observed_at=now), now))

    def test_admin_import_and_read_without_modifying_holdings(self):
        engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
        self.addCleanup(engine.dispose)
        Base.metadata.create_all(engine)
        with Session(engine) as db:
            user = User(email="reviewer@example.com", password_hash="unused", is_superuser=False)
            db.add_all([user, Stock(symbol="BANK")])
            db.commit()
            main.app.dependency_overrides[get_db] = lambda: db
            main.app.dependency_overrides[get_current_user] = lambda: user
            self.addCleanup(main.app.dependency_overrides.clear)
            def put(url, json):
                async def request():
                    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app),
                                                 base_url="http://test") as client:
                        return await client.put(url, json=json)
                return asyncio.run(request())
            payload = statement().model_dump(mode="json")
            url = "/admin/stocks/BANK/financial-statements"
            self.assertEqual(put(url, json=payload).status_code, 403)
            user.is_superuser = True
            response = put(url, json=payload)
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["statements"][0]["metrics"]["revenue"], 1200)
            payload["metrics"]["revenue"] = 1300
            self.assertEqual(put(url, json=payload).status_code, 200)
            self.assertEqual(len(list(db.scalars(select(FinancialStatement)))), 1)
            self.assertEqual(get_financials(db, "BANK").statements[0].metrics.revenue, 1300)
            self.assertEqual(put("/admin/stocks/UNKNOWN/financial-statements", json=payload).status_code, 404)

    def test_no_carry_forward_after_failed_fundamentals_sync(self):
        engine = create_engine("sqlite://")
        self.addCleanup(engine.dispose)
        Base.metadata.create_all(engine)
        now = datetime.now(timezone.utc)
        with Session(engine) as db:
            db.add(Stock(symbol="BANK"))
            db.add_all([FundamentalObservation(observation_key="old", stock_symbol="BANK", source="ngxpulse",
                observed_at=now - timedelta(days=1), inputs={"fundamentals": {"pb_ratio": .41}}),
                FundamentalObservation(observation_key="new", stock_symbol="BANK", source="ngxpulse",
                observed_at=now, inputs={})])
            db.commit()
            self.assertIsNone(get_financials(db, "BANK").valuation)
