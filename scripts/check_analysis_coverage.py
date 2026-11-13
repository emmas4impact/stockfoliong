"""Measure the deployed model's actual coverage, without inferring scores from /stocks."""

import argparse
from collections import Counter, defaultdict
from getpass import getpass
import json
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check_coverage(call):
    stocks = call("/stocks")
    symbols = sorted({stock["symbol"] for stock in stocks})
    scored = 0
    sources = Counter()
    unavailable = Counter()
    reasons = Counter()
    sectors = defaultdict(lambda: {"scored": 0, "total": 0})
    samples = {}
    for symbol in symbols:
        path = "/stocks/" + quote(symbol, safe="") + "/analysis"
        try:
            row = call(path)
        except HTTPError as exc:
            if exc.code != 503:
                raise
            try:
                detail = json.load(exc).get("detail")
            except (ValueError, AttributeError):
                raise RuntimeError("Backend returned an unexpected 503 for " + symbol) from exc
            if detail != "Analysis awaits a successful market data sync":
                raise RuntimeError("Backend unavailable while checking " + symbol) from exc
            unavailable["no_observation"] += 1
            sectors["(no observation)"]["total"] += 1
            continue
        sector = row["inputs"].get("sector") or "(unknown sector)"
        sectors[sector]["total"] += 1
        sources[row["source"]] += 1
        valuation = row["scores"]["valuation"]
        if valuation is None:
            unavailable["unscored_observation"] += 1
            reasons.update(set(row["reasons"]))
        else:
            scored += 1
            sectors[sector]["scored"] += 1
        # Prefer a scored example within each sector when one is available.
        if sector not in samples or (samples[sector][1] is None and valuation is not None):
            samples[sector] = (symbol, valuation, path, row["observed_at"])

    history_checks = []
    for sector, (symbol, valuation, path, observed) in sorted(
        samples.items(), key=lambda item: (item[1][1] is None, item[0])
    )[:3]:
        history = call(path + "/history?limit=1")
        history_checks.append({
            "sector": sector, "symbol": symbol, "valuation": valuation, "observed_at": observed,
            "saved_model": history[0]["model_version"] if history and history[0]["symbol"] == symbol else None,
        })
    return {
        "listed": len(symbols), "scored": scored,
        "coverage_percent": round(100 * scored / len(symbols), 1) if symbols else None,
        "unavailable": dict(unavailable), "reasons_may_overlap": dict(reasons),
        "observation_sources": dict(sources), "by_sector": dict(sectors),
        "sample_history_checks": history_checks,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("api_base")
    parser.add_argument("--sync", action="store_true", help="Request one stock sync first (admin only)")
    args = parser.parse_args()
    base = args.api_base.rstrip("/")
    url = urlsplit(base)
    if not url.hostname or url.username or url.password or url.query or url.fragment or not (
        url.scheme == "https" or (url.scheme == "http" and url.hostname in {"localhost", "127.0.0.1", "::1"})
    ):
        parser.error("Use an HTTPS backend URL without credentials, or HTTP on localhost.")
    token = None
    opener = build_opener(NoRedirect())

    def call(path, body=None, method=None):
        headers = {"Accept": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = Request(base + path, None if body is None else json.dumps(body).encode(),
                          headers=headers, method=method)
        with opener.open(request, timeout=180 if method == "POST" else 30) as response:
            return json.load(response)

    print("Checking " + base, file=sys.stderr)
    token = call("/auth/login", {"email": input("Email: ").strip(), "password": getpass()})["access_token"]
    if args.sync:
        result = call("/admin/sync/stocks?include_history=false", method="POST")
        print(f"Sync: {result['status']}, source={result['source']}, stocks={result['stocks_upserted']}", file=sys.stderr)
        if (result["status"] != "success" or result["source"] not in {"ngxpulse", "ngx_doclib"}
                or result["stocks_upserted"] < 1):
            raise RuntimeError("No live-provider sync confirmed; not reporting old data as a fresh run.")
    print("Checking listed stocks sequentially...", file=sys.stderr)
    report = check_coverage(call)
    print(json.dumps(report, indent=2))
    if not report["listed"] or not report["sample_history_checks"] or any(
        not row["saved_model"] for row in report["sample_history_checks"]
    ):
        raise RuntimeError("Saved model history could not be confirmed.")


if __name__ == "__main__":
    try:
        main()
    except HTTPError as exc:
        sys.exit(f"HTTP {exc.code} on {urlsplit(exc.url).path}. Check login, permissions and deployment.")
    except (URLError, TimeoutError, ValueError, KeyError, RuntimeError) as exc:
        sys.exit("Coverage check did not complete: " + str(exc))
