import os
import unittest
from datetime import datetime, timezone
from unittest.mock import patch

os.environ.setdefault("DATABASE_URL", "sqlite://")
os.environ.setdefault("JWT_SECRET_KEY", "test-only-not-a-deployment-secret")

from backend.app import ngx_client as client
from backend.app import services


class DisclosureTests(unittest.TestCase):
    def test_one_bulk_fetch_distinguishes_same_title_and_keeps_latest_revision(self):
        base = {"symbol": "chams", "company": "CHAMS PLC", "type": "DirectorsDealings",
                "title": "CHAMS PLC DIRECTORSDEALINGS", "created": "2026-11-10T17:15:03+00:00"}
        url = "https://doclib.ngxgroup.com/docs/"
        rows = [dict(base, url=url + "38_Dealing_A.pdf"), dict(base, url=url + "38_Dealing_B.pdf"),
                dict(base, title="CHAMS PLC-Amended notice", url=url + "38_Dealing_A.pdf#page=1",
                     modified="2026-11-11T12:00:00+00:00"),
                dict(base, symbol="GTCO", title="", type="Corporate Actions", url=url + "42_Total_voting_rights.pdf"),
                dict(base, url="javascript:alert(1)")]
        client.clear_runtime_caches()
        self.addCleanup(client.clear_runtime_caches)
        with patch.object(client, "_kobo_feed", return_value={"data": rows}) as fetch:
            filings = services.get_cached_disclosures(None, "CHAMS")
            self.assertEqual([f["title"] for f in filings], ["Amended notice", "Dealing B"])
            self.assertEqual(filings[0]["published_at"], base["created"])
            self.assertEqual(services.get_cached_disclosures(None, "gtco")[0]["title"], "Total voting rights")
            self.assertEqual(services.get_cached_disclosures(None, "gtco")[0]["category"], "Corporate Actions")
            fetch.assert_called_once_with("ngxdata/disclosures", authenticated=True)

    def test_curated_offers_only_and_extension_replaces_original(self):
        now = datetime(2026, 11, 12, tzinfo=timezone.utc)
        offer = {"id": "A", "name": "Acme", "type_label": "Rights issue", "status": "open",
                 "end_date": "2026-11-19", "symbol": "ACME"}
        rows = [offer, dict(offer, end_date="2026-11-25"),
                dict(offer, id="B", status="completed"), dict(offer, id="C", end_date="2026-11-11"),
                dict(offer, id="D", type_label="IPO", symbol=None, start_date="2026-11-14"),
                dict(offer, id="E"), dict(offer, id="E", status="closed")]
        snapshot = {"updated_at": now.isoformat(), "data": rows}
        with patch.object(client, "_offer_snapshot", return_value=snapshot):
            upcoming, active = client.active_offers(now)
            self.assertEqual((upcoming["kind"], upcoming["status"], str(upcoming["next_date"])),
                             ("IPO", "Upcoming", "2026-11-14"))
            self.assertEqual((active["status"], str(active["next_date"])), ("Open", "2026-11-25"))
            snapshot["updated_at"] = "2026-11-01T00:00:00+00:00"
            self.assertEqual(client.active_offers(now), [])
