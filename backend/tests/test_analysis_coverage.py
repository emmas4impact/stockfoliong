import io
import json
import unittest
from urllib.error import HTTPError

from scripts.check_analysis_coverage import check_coverage


def unavailable(detail):
    return HTTPError("https://example.test", 503, "Unavailable", {},
                     io.BytesIO(json.dumps({"detail": detail}).encode()))


class CoverageTest(unittest.TestCase):
    def test_reports_full_universe_and_checks_history(self):
        def call(path):
            if path == "/stocks":
                return [{"symbol": s} for s in ["A", "B", "C"]]
            if path == "/stocks/C/analysis":
                raise unavailable("Analysis awaits a successful market data sync")
            if path == "/stocks/B/analysis/history?limit=1":
                return [{"symbol": "B", "model_version": "sector-pe-v1"}]
            self.assertIn(path, ["/stocks/A/analysis", "/stocks/B/analysis"])
            return {"inputs": {"sector": "banks"}, "source": "ngxpulse",
                    "scores": {"valuation": 0 if "/B/" in path else None},
                    "reasons": ["missing P/E"], "observed_at": "2026-11-12T10:00:00Z"}

        report = check_coverage(call)
        self.assertEqual(report["coverage_percent"], 33.3)
        self.assertEqual(report["unavailable"], {"no_observation": 1, "unscored_observation": 1})
        self.assertEqual(report["reasons_may_overlap"], {"missing P/E": 1})
        self.assertEqual(report["by_sector"]["banks"], {"scored": 1, "total": 2})
        self.assertEqual(report["sample_history_checks"][0]["saved_model"], "sector-pe-v1")

    def test_service_outage_is_not_missing_data(self):
        def call(path):
            if path == "/stocks":
                return [{"symbol": "A"}]
            raise unavailable("Service unavailable")

        with self.assertRaises(RuntimeError):
            check_coverage(call)
