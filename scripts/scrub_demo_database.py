"""Remove private rows from an offline demo database copy. Defaults to count-only."""
import argparse
import os
from pathlib import Path

from sqlalchemy import create_engine, delete, func, select, table
from sqlalchemy.engine import make_url
from sqlalchemy.exc import SQLAlchemyError


# Delete relationships first; do not keep re-identifiable portfolios or free text.
PRIVATE_TABLES = (
    "push_device_tokens", "portfolio_alert_states", "portfolio_holdings",
    "account_deletion_requests", "users", "sync_logs", "api_cache",
)


def scrub(engine, apply=False):
    with engine.begin() as connection:
        counts = {}
        for name in PRIVATE_TABLES:
            target = table(name)
            counts[name] = connection.scalar(select(func.count()).select_from(target))
            if apply:
                connection.execute(delete(target))
        return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply-to", metavar="DEMO_DB_NAME", help="Confirm exact disposable database name")
    args = parser.parse_args()
    raw = os.environ.get("DEMO_DATABASE_URL")
    if not raw:
        parser.error("Set DEMO_DATABASE_URL explicitly. The app's DATABASE_URL is never used.")
    try:
        url = make_url(raw)
        name = url.database or ""
        if url.get_backend_name() == "sqlite":
            if not Path(name).is_file():
                parser.error("Expected an existing SQLite copy.")
            name = Path(name).stem
        elif url.get_backend_name() != "postgresql" or url.host not in {"localhost", "127.0.0.1", "::1"}:
            parser.error("Use a local SQLite or loopback PostgreSQL copy.")
        if url.query or not name.endswith("_demo") or (args.apply_to is not None and args.apply_to != name):
            parser.error("Expected a database ending in _demo, no connection overrides, and exact confirmation.")
        engine = create_engine(url, echo=False)
        try:
            counts = scrub(engine, apply=args.apply_to is not None)
        finally:
            engine.dispose()
    except (ValueError, SQLAlchemyError):
        parser.exit(1, "Could not process the demo database. Check its connection and schema.\n")
    print("Removed rows:" if args.apply_to is not None else "Dry run; rows that would be removed:")
    for key, value in counts.items():
        print(f"{key}: {value}")


if __name__ == "__main__":
    main()
