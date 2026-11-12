"""Authenticated field encryption. Keys belong in server secrets, never the DB."""

import base64
import binascii
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESSIV
from sqlalchemy import Text
from sqlalchemy.types import TypeDecorator

from .settings import get_settings


class PersonalDataError(RuntimeError):
    pass


def cipher() -> AESSIV:
    secret = get_settings().personal_data_key
    try:
        key = base64.b64decode(secret.get_secret_value() if secret else "", altchars=b"-_", validate=True)
    except (ValueError, binascii.Error):
        raise PersonalDataError("PERSONAL_DATA_KEY must be base64url-encoded 64 random bytes") from None
    if len(key) != 64:
        raise PersonalDataError("PERSONAL_DATA_KEY must be base64url-encoded 64 random bytes")
    return AESSIV(key)


def encrypt(value: str, scope: str, searchable: bool = False) -> str:
    mode = "s" if searchable else "r"
    prefix = f"pd1:{mode}:"
    # SIV permits deterministic equality searches. A random AAD nonce hides
    # equality for all other fields; field/version binding prevents swapping.
    nonce = b"" if searchable else os.urandom(16)
    aad = [f"{prefix}{scope}".encode(), nonce]
    payload = nonce + cipher().encrypt(value.encode("utf-8"), aad)
    return prefix + base64.urlsafe_b64encode(payload).decode("ascii")


def decrypt(value: str, scope: str, searchable: bool = False) -> str:
    prefix = "pd1:s:" if searchable else "pd1:r:"
    if not value.startswith(prefix):
        raise PersonalDataError("Unencrypted personal data found; run the personal-data migration")
    try:
        payload = base64.b64decode(value[len(prefix):], altchars=b"-_", validate=True)
        nonce, ciphertext = (b"", payload) if searchable else (payload[:16], payload[16:])
        return cipher().decrypt(ciphertext, [f"{prefix}{scope}".encode(), nonce]).decode("utf-8")
    except (InvalidTag, ValueError, UnicodeError, binascii.Error):
        raise PersonalDataError("Cannot decrypt personal data; check key and data integrity") from None


class EncryptedText(TypeDecorator):
    impl = Text
    cache_ok = True

    def __init__(self, scope: str, searchable: bool = False):
        super().__init__()
        self.scope = scope
        self.searchable = searchable

    def process_bind_param(self, value, dialect):
        if getattr(dialect, "_personal_data_encrypted", True) is False:
            return self._legacy_value(value)
        return None if value is None else encrypt(value, self.scope, self.searchable)

    def process_result_value(self, value, dialect):
        if getattr(dialect, "_personal_data_encrypted", True) is False:
            return self._legacy_value(value)
        return None if value is None else decrypt(value, self.scope, self.searchable)

    @staticmethod
    def _legacy_value(value):
        if value is not None and value.startswith(("pd1:s:", "pd1:r:")):
            raise PersonalDataError("Encrypted personal data found in an unmigrated database; refusing plaintext mode")
        return value
