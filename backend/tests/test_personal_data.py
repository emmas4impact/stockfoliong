import base64
import os
import unittest
from unittest.mock import patch

os.environ.setdefault("DATABASE_URL", "sqlite://")
os.environ.setdefault("JWT_SECRET_KEY", "test-only-not-a-deployment-secret")

from pydantic import SecretStr
from sqlalchemy import create_engine, inspect, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from backend.app.auth import create_access_token, get_current_user, hash_password, verify_password
from backend.app.database import Base
from backend.app.models import AccountDeletionRequest, PortfolioHolding, PushDeviceToken, User
from backend.app.personal_data import PersonalDataError, decrypt, encrypt
from backend.app.personal_data_migration import STATE_TABLE, counts, migrate, protected_tables, require_ready
from backend.app.settings import get_settings


class PersonalDataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.password_hash = hash_password("existing-test-password")

    def setUp(self):
        self.key = SecretStr(base64.urlsafe_b64encode(os.urandom(64)).decode())
        self.key_patch = patch.object(get_settings(), "personal_data_key", self.key)
        self.key_patch.start()
        self.addCleanup(self.key_patch.stop)
        url = os.environ.get("TEST_PERSONAL_DATA_DATABASE_URL", "sqlite://")
        parsed = make_url(url)
        if parsed.get_backend_name() != "sqlite":
            if parsed.database != "ngx_privacy_test" or parsed.host not in {"localhost", "127.0.0.1"}:
                raise RuntimeError("Integration tests require a dedicated local ngx_privacy_test database")
        self.engine = create_engine(url, hide_parameters=True)
        self.addCleanup(self.engine.dispose)
        Base.metadata.create_all(self.engine)
        self.addCleanup(self.clean_database)
        with self.engine.begin() as conn:
            if conn.dialect.name == "postgresql":
                conn.execute(text("ALTER TABLE users ALTER COLUMN email TYPE VARCHAR(255)"))
            conn.execute(text("""
                INSERT INTO users (id, email, password_hash, full_name, phone,
                    address, city, profile_image_url, email_verified, is_superuser,
                    email_verification_token, password_reset_token)
                VALUES (1, 'investor@example.test', :password, 'Test Investor', '0123456789',
                    '123 Test Street', 'Test City', 'data:image/png;base64,TEST', true, false,
                    'verification-token', 'reset-token')
            """), {"password": self.password_hash})
            conn.execute(text("INSERT INTO stocks (symbol) VALUES ('TEST')"))
            conn.execute(text("""
                INSERT INTO portfolio_holdings (id, user_id, stock_symbol, quantity, avg_purchase_price, notes)
                VALUES (1, 1, 'TEST', 123.4567, 10.1234, 'Private investment note')
            """))
            conn.execute(text("""
                INSERT INTO push_device_tokens (id, user_id, token, platform, device_label)
                VALUES (1, 1, 'push-token', 'android', 'My personal device')
            """))
            conn.execute(text("""
                INSERT INTO account_deletion_requests (id, email, reason, source, status)
                VALUES (1, 'investor@example.test', 'Private reason', 'web', 'pending')
            """))

    def clean_database(self):
        with self.engine.begin() as conn:
            conn.execute(text(f"DROP TABLE IF EXISTS {STATE_TABLE}"))
            Base.metadata.drop_all(conn)

    def apply(self):
        with self.engine.begin() as conn:
            return migrate(conn)

    def test_authenticated_encryption_and_randomisation(self):
        for value in ("", "Lagos", "Name with \u00e9", "x" * 1_000_000):
            encrypted = encrypt(value, "users.full_name")
            self.assertEqual(decrypt(encrypted, "users.full_name"), value)
            self.assertNotEqual(encrypted, encrypt(value, "users.full_name"))
            with self.assertRaises(PersonalDataError):
                decrypt(encrypted, "users.city")
        self.assertEqual(encrypt("email", "users.email", True), encrypt("email", "users.email", True))
        self.assertNotEqual(encrypt("email", "users.email", True), encrypt("email", "other.email", True))

    def test_plaintext_corruption_and_missing_key_rejected(self):
        for value in ("plaintext", "pd1:r:bad-data", "pd1:r:" + "A" * 64):
            with self.assertRaises(PersonalDataError):
                decrypt(value, "users.full_name")
        for key in (None, SecretStr("invalid!"), SecretStr(base64.urlsafe_b64encode(b"short").decode())):
            with patch.object(get_settings(), "personal_data_key", key):
                with self.assertRaises(PersonalDataError):
                    encrypt("value", "users.full_name")

    def test_dry_run_and_startup_guard(self):
        with self.engine.connect() as conn:
            self.assertTrue(all(count == 1 for count in counts(conn).values()))
            with self.assertRaises(PersonalDataError):
                require_ready(conn)
            self.assertEqual(conn.scalar(text("SELECT email FROM users")), "investor@example.test")
            self.assertFalse(inspect(conn).has_table(STATE_TABLE))

    def test_existing_credentials_sessions_and_lookup_tokens_survive(self):
        token = create_access_token(1)
        self.apply()
        with Session(self.engine) as db:
            user = db.scalar(select(User).where(User.email == "investor@example.test"))
            self.assertEqual(user.id, 1)
            self.assertTrue(verify_password("existing-test-password", user.password_hash))
            self.assertEqual(user.password_hash, self.password_hash)
            self.assertEqual(get_current_user(token, db).id, user.id)
            self.assertEqual(user.full_name, "Test Investor")
            self.assertEqual(user.profile_image_url, "data:image/png;base64,TEST")
            self.assertEqual(db.scalar(select(User).where(User.password_reset_token == "reset-token")).id, 1)
            self.assertEqual(db.scalar(select(User).where(User.email_verification_token == "verification-token")).id, 1)
            self.assertEqual(db.scalar(select(PushDeviceToken).where(PushDeviceToken.token == "push-token")).device_label,
                             "My personal device")
            holding = db.get(PortfolioHolding, 1)
            self.assertEqual(str(holding.quantity), "123.4567")
            self.assertEqual(str(holding.avg_purchase_price), "10.1234")
            self.assertEqual(holding.notes, "Private investment note")
            self.assertEqual(db.get(AccountDeletionRequest, 1).reason, "Private reason")

    def test_all_nonnull_protected_fields_encrypted_and_timestamps_preserved(self):
        with self.engine.begin() as conn:
            before = conn.execute(text("SELECT created_at, updated_at FROM users")).one()
            if conn.dialect.name == "postgresql":
                conn.execute(text("ALTER TABLE users DROP COLUMN country"))
        self.apply()
        with self.engine.connect() as conn:
            require_ready(conn)
            for name, columns in protected_tables().items():
                for column in columns:
                    value = conn.scalar(text(f'SELECT "{column.name}" FROM "{name}"'))
                    if value is not None:
                        self.assertTrue(value.startswith("pd1:"), f"{name}.{column.name}")
                        decrypt(value, column.type.scope, column.type.searchable)
            self.assertEqual(before, conn.execute(text("SELECT created_at, updated_at FROM users")).one())
            if conn.dialect.name == "postgresql":
                email = next(c for c in inspect(conn).get_columns("users") if c["name"] == "email")
                self.assertEqual(str(email["type"]), "TEXT")

    def test_new_accounts_updates_nulls_and_unique_email(self):
        self.apply()
        with Session(self.engine) as db:
            user = User(id=2, email="new@example.test", password_hash=self.password_hash, full_name="New Name")
            db.add(user)
            db.commit()
            db.refresh(user)
            self.assertEqual(user.email, "new@example.test")
            self.assertIsNone(user.phone)
            user.full_name = "Updated Name"
            user.password_reset_token = "new-reset-token"
            db.commit()
            db.expire_all()
            self.assertEqual(db.scalar(select(User).where(User.password_reset_token == "new-reset-token")).full_name,
                             "Updated Name")
            user.password_reset_token = None
            db.commit()
            self.assertIsNone(db.scalar(select(User).where(User.password_reset_token == "new-reset-token")))
            self.assertNotEqual(db.scalar(text("SELECT full_name FROM users WHERE id = 2")), "Updated Name")
            db.add(User(id=3, email="new@example.test", password_hash=self.password_hash))
            with self.assertRaises(IntegrityError):
                db.commit()
            db.rollback()

    def test_idempotent_and_wrong_key_fails_before_writes(self):
        self.apply()
        with self.engine.connect() as conn:
            original = conn.scalar(text("SELECT full_name FROM users"))
        self.assertTrue(all(count == 0 for count in self.apply().values()))
        with patch.object(get_settings(), "personal_data_key", SecretStr(base64.urlsafe_b64encode(os.urandom(64)).decode())):
            with self.assertRaises(PersonalDataError):
                self.apply()
        with self.engine.connect() as conn:
            self.assertEqual(conn.scalar(text("SELECT full_name FROM users")), original)

    def test_migration_failure_rolls_back_all_rows(self):
        calls = 0

        def interrupt(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 8:
                raise RuntimeError("simulated interruption")
            return encrypt(*args, **kwargs)

        with patch("backend.app.personal_data_migration.encrypt", side_effect=interrupt):
            with self.assertRaises(RuntimeError):
                self.apply()
        with self.engine.connect() as conn:
            self.assertEqual(conn.scalar(text("SELECT email FROM users")), "investor@example.test")
            self.assertEqual(conn.scalar(text("SELECT reason FROM account_deletion_requests")), "Private reason")
            self.assertFalse(inspect(conn).has_table(STATE_TABLE))

    def test_orm_plaintext_reads_fail_closed(self):
        with Session(self.engine) as db:
            with self.assertRaises(PersonalDataError):
                db.get(User, 1)

    def test_fresh_database_initialisation(self):
        self.clean_database()
        self.assertTrue(all(count == 0 for count in self.apply().values()))
        with self.engine.connect() as conn:
            require_ready(conn)

    def test_api_registration_login_profile_verification_and_password_reset(self):
        from backend.app import main
        from backend.app.schemas import LoginRequest, PasswordResetConfirm, PasswordResetRequest, ProfileUpdate, RegisterRequest, UserOut

        self.clean_database()
        self.apply()
        with Session(self.engine) as db:
            user = main.register(RegisterRequest(email="Investor@example.com", password="test-password-123", full_name="Investor"), db)
            user_id = user.id
            response = UserOut.model_validate(user).model_dump()
            self.assertEqual(response["email"], "investor@example.com")
            self.assertNotIn("password_hash", response)
            self.assertNotIn("email_verification_token", response)
            login = main.login(LoginRequest(email="INVESTOR@example.com", password="test-password-123"), db)
            self.assertEqual(get_current_user(login.access_token, db).id, user_id)
            main.verify_email(user.email_verification_token, db)
            db.refresh(user)
            self.assertTrue(user.email_verified)
            self.assertIsNone(user.email_verification_token)
            updated = main.update_me(ProfileUpdate(full_name="Updated Investor", city="Lagos", phone="12345"), db, user)
            self.assertEqual(UserOut.model_validate(updated).city, "Lagos")
            with patch.object(main.settings, "resend_api_key", "test-key"), patch.object(main.settings, "resend_from_email", "noreply@example.com"), patch.object(main, "send_email") as send:
                main.forgot_password(PasswordResetRequest(email="INVESTOR@example.com"), db)
                self.assertEqual(send.call_args.kwargs["to_email"], "investor@example.com")
                db.refresh(user)
                reset_token = user.password_reset_token
                self.assertIn(reset_token, send.call_args.kwargs["body"])
            main.reset_password(PasswordResetConfirm(token=reset_token, new_password="replacement-password"), db)
            login = main.login(LoginRequest(email="investor@example.com", password="replacement-password"), db)
            self.assertEqual(get_current_user(login.access_token, db).id, user_id)
            with self.assertRaises(main.HTTPException):
                main.login(LoginRequest(email="investor@example.com", password="test-password-123"), db)
            with self.assertRaises(main.HTTPException):
                main.reset_password(PasswordResetConfirm(token=reset_token, new_password="replacement-password"), db)


if __name__ == "__main__":
    unittest.main()
