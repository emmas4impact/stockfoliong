import asyncio
import os
import unittest
from datetime import date, datetime, timedelta, timezone
from unittest.mock import patch

os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "test-only-not-a-deployment-secret"

import httpx
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from backend.app import main
from backend.app.auth import get_current_user
from backend.app.data_quality import data_quality_report
from backend.app.database import Base, get_db
from backend.app.models import FinancialStatement, FundamentalObservation, Stock, StockAnalysis, StockPrice, User


class DataQualityTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
        Base.metadata.create_all(self.engine)
        self.db = Session(self.engine)
        self.addCleanup(self.engine.dispose)
        self.addCleanup(self.db.close)
        self.now = datetime.now(timezone.utc)

    def observation(self, symbol, **changes):
        fields = dict(observation_key=symbol, stock_symbol=symbol, source="ngxpulse",
                      observed_at=self.now, inputs={"sector": "banks", "pe_ratio": 10,
                          "fundamentals": {"pe_ratio": 10, "updated_at": self.now.isoformat()}})
        fields.update(changes)
        row = FundamentalObservation(**fields)
        self.db.add(row)
        return row

    def statement(self, symbol, year, **changes):
        payload = dict(fiscal_year=year, basis="annual", period_start=f"{year}-01-01",
                       period_end=f"{year}-12-31", currency="NGN", scope="consolidated", audited=True,
                       source_url="https://doclib.ngxgroup.com/report.pdf", source_title="Report",
                       reviewed=True, metrics={"revenue": 1200, "eps": 2})
        payload.update(changes)
        return FinancialStatement(stock_symbol=symbol, period_key=f"{year}:0:annual:consolidated", payload=payload)

    def test_empty_database_has_no_fake_percentages(self):
        report = data_quality_report(self.db, self.now)
        self.assertEqual(report["listed"], 0)
        self.assertEqual(report["stocks"], [])
        self.assertEqual(report["coverage"]["pe_scored"], {"count": 0, "percent": None})
        self.assertIsNone(report["instrument_audit"]["stored_company_share_coverage"]["pe_scored"]["percent"])

    def test_dated_reference_separates_share_coverage_from_all_record_coverage(self):
        for symbol in ["ACCESSCORP", "TIP", "UHREIT", "NIDF", "FG123UNKNOWN"]:
            self.db.add(Stock(symbol=symbol))
            if symbol != "TIP":
                self.observation(symbol)
        self.db.commit()
        report = data_quality_report(self.db, self.now)
        audit = report["instrument_audit"]
        self.assertEqual(report["coverage"]["pe_scored"], {"count": 4, "percent": 80.0})
        self.assertEqual(audit["stored_company_shares"], 2)
        self.assertEqual(audit["stored_funds_or_trusts"], 2)
        self.assertEqual(audit["unverified_symbols"], ["FG123UNKNOWN"])
        self.assertEqual(audit["stored_company_share_coverage"]["pe_scored"], {"count": 1, "percent": 50.0})
        self.assertNotIn("TIP", audit["reference_company_shares_not_in_db"])
        self.assertIn("UBA", audit["reference_company_shares_not_in_db"])

    def test_full_universe_coverage_and_no_writes(self):
        for symbol in ["A", "B", "C", "D", "EMPTY"]:
            self.db.add(Stock(symbol=symbol, sector="Banks"))
        for symbol in ["A", "B", "C", "D"]:
            row = self.observation(symbol)
            if symbol == "A":
                # The highest P/E earns a valid zero score, not a missing score.
                row.inputs = {"sector": "banks", "pe_ratio": 20,
                              "fundamentals": {"pe_ratio": 20, "pb_ratio": 1, "updated_at": self.now.isoformat()}}
        old = self.observation("A", observation_key="older-fundamentals",
            observed_at=self.now - timedelta(days=1), inputs={"fundamentals": {
                "pe_ratio": 20, "pb_ratio": 1, "updated_at": self.now.isoformat()}})
        self.db.add_all([self.statement("A", self.now.year - 2), self.statement("A", self.now.year - 1),
            StockPrice(stock_symbol="A", trade_date=date.today(), close_price=10)])
        self.db.flush()
        self.db.add(StockAnalysis(stock_symbol="A", observation_id=old.id, analysis_key="saved",
                                 model_version="sector-pe-v1", generated_at=self.now, result={}))
        self.db.commit()
        queries = []
        def capture(conn, cursor, statement, parameters, context, executemany):
            queries.append(statement.strip().split()[0].upper())
        event.listen(self.engine, "before_cursor_execute", capture)
        report = data_quality_report(self.db, self.now)
        self.assertEqual(report["listed"], 5)
        self.assertEqual(report["coverage"]["pe_scored"], {"count": 4, "percent": 80.0})
        self.assertEqual(report["coverage"]["current_positive_pe_pb"]["count"], 1)
        self.assertEqual(report["coverage"]["revenue_and_eps_yoy"]["count"], 1)
        a = report["stocks"][0]
        self.assertEqual(a["valuation"]["pe_ratio"], 20)
        self.assertIn("missing_or_invalid_publication_date", a["issues"])
        self.assertEqual(a["analysis_history"]["rows"], 1)
        self.assertEqual(a["price_history"]["rows"], 1)
        self.assertEqual(set(queries), {"SELECT"})
        self.assertEqual(len(queries), 6)

    def test_quote_only_observation_preserves_display_but_not_confirmed_score(self):
        self.db.add(Stock(symbol="A"))
        self.observation("A", observation_key="valuation", observed_at=self.now - timedelta(days=1),
                         inputs={"fundamentals": {"pe_ratio": 10, "pb_ratio": 1,
                                                 "updated_at": self.now.isoformat()}})
        self.observation("A", inputs={"pe_ratio": 10})
        self.db.commit()
        row = data_quality_report(self.db, self.now)["stocks"][0]
        self.assertEqual(row["valuation"]["pe_ratio"], 10)
        self.assertTrue(row["current_positive_pe_pb"])
        self.assertEqual(row["pe_freshness"], "unknown")
        self.assertFalse(row["pe_scored"])

    def test_peer_preview_separates_exclusions_from_lost_or_changed_company_labels(self):
        for sector, values in [
            ("property", {"JBERGER": 20, "UPDC": 100, "UHREIT": 1, "SFSREIT": 2, "UPDCREIT": 3}),
            ("comparison", {"UBA": 10, "GTCO": 10, "FCMB": 10, "WEMABANK": 15,
                            "UNMATCHED1": 100, "UNMATCHED2": 100, "UNMATCHED3": 100}),
        ]:
            for symbol, value in values.items():
                self.db.add(Stock(symbol=symbol, sector=sector, open_price=1, last_price=1))
                self.observation(symbol, inputs={"sector": sector, "pe_ratio": value, "fundamentals": {
                    "pe_ratio": value, "pb_ratio": value, "updated_at": self.now.isoformat()}})
        # A current ratio without an opening quote participates in P/E scoring, not home signals.
        self.db.add(Stock(symbol="NREIT", sector="property", last_price=1))
        self.observation("NREIT", inputs={"sector": "property", "pe_ratio": 5, "fundamentals": {
            "pe_ratio": 5, "pb_ratio": 5, "updated_at": self.now.isoformat()}})
        self.db.commit()
        preview = data_quality_report(self.db, self.now)["company_peer_preview"]
        scores = {r["symbol"]: r for r in preview["company_pe_peer_changes"]}
        self.assertEqual(scores["UPDC"]["before"], 0)
        self.assertIsNone(scores["UPDC"]["after"])
        self.assertEqual(scores["UPDC"]["peers_after"], 1)
        signals = {r["symbol"]: (r["before"], r["after"]) for r in preview["company_signal_changes"]}
        self.assertEqual(signals["UPDC"], ("Sell", None))
        self.assertEqual(signals["WEMABANK"], ("Buy", "Sell"))
        self.assertEqual(preview["company_signals_before"], 6)
        self.assertEqual(preview["company_signals_after"], 4)
        self.assertIn({"symbol": "NREIT", "instrument_class": "fund_or_trust"}, preview["excluded_scored_instruments"])
        self.assertNotIn("NREIT", preview["excluded_signal_symbols"])

    def test_stale_unknown_invalid_and_future_metadata(self):
        cases = {
            "STALE": {"fundamentals_received_at": (self.now - timedelta(days=8)).isoformat(),
                      "fundamentals": {"pe_ratio": 2, "pb_ratio": .5, "updated_at": self.now.isoformat()}},
            "UNKNOWN": {"fundamentals": {"pe_ratio": 2, "pb_ratio": .5}},
            "INVALID": {"fundamentals_received_at": "broken", "fundamentals": {"pe_ratio": 2}},
            "FUTURE": {"published_at": (self.now + timedelta(days=1)).isoformat(),
                       "reporting_period": (self.now + timedelta(days=2)).isoformat()},
            "NEGATIVE": {"fundamentals": {"pe_ratio": -2, "pb_ratio": .5, "updated_at": self.now.isoformat()}},
        }
        for symbol, inputs in cases.items():
            self.db.add(Stock(symbol=symbol))
            self.observation(symbol, inputs=inputs)
        self.db.commit()
        report = data_quality_report(self.db, self.now)
        rows = {row["symbol"]: row for row in report["stocks"]}
        self.assertEqual(report["coverage"]["current_positive_pe_pb"]["count"], 0)
        for symbol, issue in [("STALE", "valuation_stale"), ("UNKNOWN", "valuation_unknown"),
                              ("INVALID", "invalid_valuation_metadata"), ("FUTURE", "future_publication_date"),
                              ("NEGATIVE", "positive_pe_pb_unavailable")]:
            self.assertIn(issue, rows[symbol]["issues"])

    def test_bad_statements_are_reported_and_incompatible_pairs_not_counted(self):
        self.db.add(Stock(symbol="A"))
        self.db.add_all([self.statement("A", self.now.year - 1),
                         self.statement("A", self.now.year - 2, currency="USD"),
                         self.statement("A", self.now.year - 3, reviewed=False)])
        self.db.commit()
        row = data_quality_report(self.db, self.now)["stocks"][0]
        self.assertEqual(row["statements"]["valid"], 2)
        self.assertEqual(row["statements"]["invalid"], 1)
        self.assertEqual(row["statements"]["comparable_yoy_pairs"], {"revenue": 0, "eps": 0})
        self.assertIn("invalid_statement_records", row["issues"])

    def test_endpoint_requires_admin_and_never_fetches_provider(self):
        main.app.dependency_overrides[get_db] = lambda: self.db
        self.addCleanup(main.app.dependency_overrides.clear)
        def get():
            async def request():
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app),
                                             base_url="http://test") as client:
                    return await client.get("/admin/analysis/data-quality")
            return asyncio.run(request())
        self.assertEqual(get().status_code, 401)
        user = User(email="audit@example.com", password_hash="unused", is_superuser=False)
        main.app.dependency_overrides[get_current_user] = lambda: user
        self.assertEqual(get().status_code, 403)
        user.is_superuser = True
        with patch("backend.app.ngx_client.requests.get", side_effect=AssertionError("No provider requests")):
            response = get()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["listed"], 0)
