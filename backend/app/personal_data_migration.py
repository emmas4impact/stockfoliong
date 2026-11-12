"""Offline, transactional upgrade of legacy plaintext personal fields."""

import logging

from sqlalchemy import inspect, text

from .database import Base
from . import models  # Register all tables before inspecting the metadata.
from .personal_data import EncryptedText, PersonalDataError, cipher, decrypt, encrypt


STATE_TABLE = "personal_data_encryption_state"
CHECK_VALUE = "stockfolio-personal-data-v1"


def configure_storage(conn) -> bool:
    """Choose one storage mode per engine, never from whether a key is present."""
    # Reset to fail-closed before validating, including a reused engine whose
    # previous startup selected legacy mode.
    conn.dialect._personal_data_encrypted = True
    inspector = inspect(conn)
    if inspector.has_table(STATE_TABLE):
        require_ready(conn)
        return True

    existing = set(inspector.get_table_names())
    for name, columns in protected_tables().items():
        if name not in existing:
            continue
        present = {column["name"] for column in inspector.get_columns(name)}
        for column in columns:
            if column.name not in present:
                continue
            found = conn.scalar(text(
                f'SELECT 1 FROM "{name}" WHERE "{column.name}" LIKE :searchable '
                f'OR "{column.name}" LIKE :randomized LIMIT 1'
            ), {"searchable": "pd1:s:%", "randomized": "pd1:r:%"})
            if found is not None:
                raise PersonalDataError("Encrypted personal data exists without its migration marker; restore the marker and key")

    conn.dialect._personal_data_encrypted = False
    logging.getLogger(__name__).warning(
        "Personal-data encryption is not enabled: using the existing unmigrated database. "
        "Provision PERSONAL_DATA_KEY and run the offline migration to enable encryption."
    )
    return False


def protected_tables():
    return {
        table.name: [column for column in table.columns if isinstance(column.type, EncryptedText)]
        for table in Base.metadata.sorted_tables
        if any(isinstance(column.type, EncryptedText) for column in table.columns)
    }


def counts(conn) -> dict[str, int]:
    existing = set(inspect(conn).get_table_names())
    return {
        name: conn.scalar(text(f'SELECT count(*) FROM "{name}"')) if name in existing else 0
        for name in protected_tables()
    }


def require_ready(conn) -> None:
    cipher()
    if not inspect(conn).has_table(STATE_TABLE):
        raise PersonalDataError("Run scripts/encrypt_personal_data.py before starting the API")
    marker = conn.scalar(text(f"SELECT key_check FROM {STATE_TABLE} WHERE id = 1"))
    if not marker or decrypt(marker, STATE_TABLE) != CHECK_VALUE:
        raise PersonalDataError("Personal-data migration is incomplete or the key is incorrect")


def migrate(conn) -> dict[str, int]:
    """Caller owns one transaction. Stop ALL old API/worker processes first."""
    cipher()
    if conn.dialect.name not in {"postgresql", "sqlite"}:
        raise PersonalDataError("Unsupported migration database")
    if conn.dialect.name == "postgresql":
        conn.execute(text("SET LOCAL lock_timeout = '10s'"))
        conn.execute(text("SELECT pg_advisory_xact_lock(7319042601)"))
    if inspect(conn).has_table(STATE_TABLE):
        require_ready(conn)
        return {name: 0 for name in protected_tables()}

    Base.metadata.create_all(conn)
    if conn.dialect.name == "postgresql":
        names = ", ".join(f'"{name}"' for name in sorted(protected_tables()))
        conn.execute(text(f"LOCK TABLE {names} IN ACCESS EXCLUSIVE MODE"))
    migrated = counts(conn)
    for name, columns in protected_tables().items():
        existing = {column["name"] for column in inspect(conn).get_columns(name)}
        for column in columns:
            if column.name not in existing:
                if not column.nullable:
                    raise PersonalDataError(f"Required migration column missing: {name}.{column.name}")
                conn.execute(text(f'ALTER TABLE "{name}" ADD COLUMN "{column.name}" TEXT'))
            elif conn.dialect.name == "postgresql":
                conn.execute(text(f'ALTER TABLE "{name}" ALTER COLUMN "{column.name}" TYPE TEXT'))
        fields = ", ".join(f'"{column.name}"' for column in columns)
        assignments = ", ".join(f'"{column.name}" = :{column.name}' for column in columns)
        last_id = -1
        # Small pages bound memory even when profiles contain embedded images.
        while True:
            rows = conn.execute(text(
                f'SELECT id, {fields} FROM "{name}" WHERE id > :last_id ORDER BY id LIMIT 10'
            ), {"last_id": last_id}).mappings().all()
            if not rows:
                break
            for row in rows:
                values = {"id": row["id"]}
                for column in columns:
                    value = row[column.name]
                    values[column.name] = None if value is None else encrypt(
                        value, column.type.scope, column.type.searchable
                    )
                conn.execute(text(f'UPDATE "{name}" SET {assignments} WHERE id = :id'), values)
            last_id = rows[-1]["id"]

    conn.execute(text(
        f"CREATE TABLE {STATE_TABLE} (id INTEGER PRIMARY KEY CHECK (id = 1), key_check TEXT NOT NULL)"
    ))
    conn.execute(text(f"INSERT INTO {STATE_TABLE} (id, key_check) VALUES (1, :check)"),
                 {"check": encrypt(CHECK_VALUE, STATE_TABLE)})
    require_ready(conn)
    return migrated
