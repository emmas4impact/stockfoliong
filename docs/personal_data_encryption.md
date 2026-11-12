# Personal Data at Rest

This is reversible server-side encryption, not anonymisation. Accounts, bcrypt
password hashes, user IDs, roles, holdings and sign-in remain intact. Web, Android
and iOS clients continue using the existing API; no encryption key goes into an app
bundle. Authorised users still see their own decrypted profiles over HTTPS.

## Coverage

- Users: email, name, profile image/URL, phone, street address, city and country.
- Email-verification and password-reset tokens.
- Push registration tokens and device labels.
- Portfolio notes and account-deletion request emails/reasons.

The implementation uses the cryptography library's authenticated AES-SIV with a
dedicated 64-byte key and table/column/version binding. Searchable values (emails
and tokens) use deterministic encryption to retain indexed exact-match lookups
and uniqueness. Other fields use a random nonce in the authenticated data.
See [cryptography's AES-SIV documentation](https://cryptography.io/en/latest/hazmat/primitives/aead/#cryptography.hazmat.primitives.ciphers.aead.AESSIV).

Equality and ciphertext length leak information. IDs, relationships, timestamps,
stock symbols, holding quantities/costs and alert price baselines remain visible
in SQL. This does not encrypt the whole database or protect against an attacker
who controls the running API and its secrets. Use encrypted database storage,
restricted access, HTTPS, and encrypted backups as additional layers.

## Deployment

Do not run `scrub_demo_database.py` on real accounts: it destroys sign-in data.
Do not deploy this API version without provisioning the key and migrating first.

1. Take and verify a recoverable database backup. Keep it access-restricted and
   encrypted; legacy backups, WAL and old physical pages may still contain
   plaintext after migration. Apply the retention policy to those copies.
2. Generate 64 cryptographically random bytes, base64url-encode them, and put the
   result in the server secret `PERSONAL_DATA_KEY`. Use a secret manager, not a
   committed file. Keep a separate recoverable key backup. Do not reuse the JWT
   secret. All API instances and workers must receive the same key.
3. Rehearse the migration and login/reset/profile/push flows on an isolated copy.
   Install the updated requirements and export `DATABASE_URL`, `JWT_SECRET_KEY`
   and `PERSONAL_DATA_KEY` into the migration process securely.
4. Stop every API replica, background worker and other writer. Count-only preview:

   ```sh
   python scripts/encrypt_personal_data.py
   ```

5. Apply, replacing the database name with the intended target:

   ```sh
   python scripts/encrypt_personal_data.py --apply --confirm-database ngx_dash
   ```

   For Compose, build the new API image without starting it, then use
   `docker compose run --rm --no-deps api python scripts/encrypt_personal_data.py`
   with the same flags. The PostgreSQL service must already be running.

6. Start only the updated API/workers. Verify login using an existing account,
   profile edits, verification/reset links, holdings and push registration on web
   and mobile. The HTTP contracts are unchanged.

The command creates missing tables on new installs, expands protected columns
to TEXT, encrypts legacy values in batches within one transaction, and records an
authenticated migration marker. Existing optional profile columns are added if
needed. All IDs, timestamps, password hashes and portfolio amounts are preserved.
Locks time out rather than waiting indefinitely. Re-running with the same key is
a no-op. The marker prevents accidentally migrating twice or starting with the
wrong key. Plaintext reads fail closed; there is no plaintext fallback.

The migration must also run before the very first API start on a fresh database.
Do not restart old API code after migrating: it cannot read ciphertext and may
write plaintext. If migration fails, the transaction rolls back; keep writers
stopped while investigating. To roll back a successful deployment, stop all
writers and restore the pre-migration backup with the matching old application;
account for any writes after the backup before doing so.

## Keys and Operations

Losing the key loses access to protected data. Simply replacing it is not key
rotation: startup will reject a mismatched key. Rotation requires a separately
tested offline re-encryption migration using both keys; this release does not
provide one. Never log keys, SQL parameters, request bodies, reset links or push
tokens. SQLAlchemy parameter logging is disabled, but database server error/query
logging and external telemetry also need redaction/access controls.

Application encryption does not remove old plaintext from exports, emails,
browser/mobile caches, third-party push providers, logs or backups. Those have
their own access controls and retention requirements.

## Local Backup Format

The local development rollout stores its recovery material in `.privacy-local/`,
excluded from Git and Docker build contexts, with directory permissions 0700
and file permissions 0600. The active key is in the ignored `.env`; a recovery
copy is in `.privacy-local/personal-data-key.env`. Keep an additional copy in a
secure off-device secret store: two files on the same disk are not disaster
recovery. Neither file should be shared or included in support logs.

Files named `pre-encryption-*.dump.siv` contain an encrypted PostgreSQL custom
archive. Their format is the six-byte header `NGXPD1`, a 16-byte random nonce,
and AES-SIV ciphertext. Decrypt with the base64-decoded 64-byte personal-data
key and associated data `[b"stockfolio-postgres-backup-v1", nonce]`. Feed the
decrypted bytes directly to `pg_restore`, without creating a plaintext dump on
disk. The local rollout verified a complete restore into a disposable database
before changing the development database. Restore only to a separate recovery
database until the recovered data has been verified; a pre-encryption archive
contains plaintext fields and must not replace a running encrypted database.
