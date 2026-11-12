#!/usr/bin/env python3
"""Count by default; explicit, offline encryption migration with --apply."""

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import create_engine
from sqlalchemy.engine import make_url

from backend.app.personal_data_migration import counts, migrate
from backend.app.settings import get_settings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirm-database", help="Exact target database name; required with --apply")
    args = parser.parse_args()
    settings = get_settings()
    url = make_url(settings.database_url)
    if args.apply and (not url.database or args.confirm_database != url.database):
        parser.error("--apply requires --confirm-database matching DATABASE_URL's database name")
    if args.apply and url.get_backend_name() != "postgresql":
        parser.error("CLI migration supports PostgreSQL only")
    engine = create_engine(url, hide_parameters=True, echo=False)
    try:
        with engine.begin() as conn:
            result = migrate(conn) if args.apply else counts(conn)
        print("Migration committed (0 means no rows changed)." if args.apply else "Dry run; no data changed.")
        for table, count in result.items():
            print(f"{table}: {count}")
        return 0
    except Exception as exc:
        # Driver messages may contain plaintext uniqueness violations. Do not
        # print SQL parameters, connection URLs, key material or driver details.
        print(f"Migration did not complete ({type(exc).__name__}); transaction rolled back.", file=sys.stderr)
        return 1
    finally:
        engine.dispose()


if __name__ == "__main__":
    raise SystemExit(main())
