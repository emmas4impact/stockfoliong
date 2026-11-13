import asyncio
import os
import unittest
from unittest.mock import patch

os.environ["DATABASE_URL"] = "sqlite://"
os.environ["JWT_SECRET_KEY"] = "test-only-not-a-deployment-secret"

from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import Session

from backend.app import main
from backend.app.auth import get_current_user, verify_password
from backend.app.database import Base
from backend.app.schemas import LoginRequest, PasswordResetConfirm, PasswordResetRequest, ProfileUpdate, RegisterRequest, UserOut
from backend.app.settings import Settings


class AuthStorageTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine("sqlite://", hide_parameters=True)
        self.addCleanup(self.engine.dispose)
        Base.metadata.create_all(self.engine)

    def test_startup_has_no_encryption_key_or_migration_requirement(self):
        self.assertNotIn("personal_data_key", Settings.model_fields)
        with patch.object(main, "engine", self.engine), patch.object(main, "ensure_runtime_schema"), patch.object(main.settings, "enable_background_stock_sync", False):
            asyncio.run(main.startup())
        self.assertNotIn("personal_data_encryption_state", inspect(self.engine).get_table_names())

    def test_passwords_remain_hashed_and_existing_email_login_works(self):
        with Session(self.engine) as db:
            user = main.register(RegisterRequest(email="Investor@example.com", password="test-password-123", full_name="Investor"), db)
            row = db.execute(text("SELECT email, password_hash, full_name FROM users")).one()
            self.assertEqual(row.email, "investor@example.com")
            self.assertEqual(row.full_name, "Investor")
            self.assertNotEqual(row.password_hash, "test-password-123")
            self.assertTrue(verify_password("test-password-123", row.password_hash))
            login = main.login(LoginRequest(email="INVESTOR@example.com", password="test-password-123"), db)
            self.assertEqual(get_current_user(login.access_token, db).id, user.id)
            self.assertNotIn("password_hash", UserOut.model_validate(user).model_dump())
            with self.assertRaises(main.HTTPException) as error:
                main.register(RegisterRequest(email="INVESTOR@example.com", password="test-password-123"), db)
            self.assertEqual(error.exception.status_code, 409)

    def test_profile_verification_and_reset_work_without_encryption(self):
        with Session(self.engine) as db:
            user = main.register(RegisterRequest(email="investor@example.com", password="test-password-123"), db)
            main.verify_email(user.email_verification_token, db)
            db.refresh(user)
            self.assertTrue(user.email_verified)
            self.assertIsNone(user.email_verification_token)
            main.update_me(ProfileUpdate(full_name="Investor", phone="12345", city="Lagos"), db, user)
            self.assertEqual(db.scalar(text("SELECT city FROM users")), "Lagos")
            with patch.object(main.settings, "resend_api_key", "test-key"), patch.object(main.settings, "resend_from_email", "noreply@example.com"), patch.object(main, "send_email") as send:
                main.forgot_password(PasswordResetRequest(email="INVESTOR@example.com"), db)
                self.assertEqual(send.call_args.kwargs["to_email"], "investor@example.com")
                db.refresh(user)
                token = user.password_reset_token
                self.assertIn(token, send.call_args.kwargs["body"])
            main.reset_password(PasswordResetConfirm(token=token, new_password="replacement-password"), db)
            main.login(LoginRequest(email="investor@example.com", password="replacement-password"), db)
            with self.assertRaises(main.HTTPException):
                main.login(LoginRequest(email="investor@example.com", password="test-password-123"), db)
            with self.assertRaises(main.HTTPException):
                main.reset_password(PasswordResetConfirm(token=token, new_password="replacement-password"), db)


if __name__ == "__main__":
    unittest.main()
