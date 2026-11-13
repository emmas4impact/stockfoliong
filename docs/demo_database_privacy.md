# Sanitising a demo database

Use an offline, disposable, schema-current clone, never the live app database.
This tool removes accounts and their credentials, holdings (including free-text
notes), alert state, device tokens, and deletion requests. It also clears sync
logs and cached payloads. Market instruments, prices, and market analyses stay.
It does **not** preserve sign-in or individual portfolio history. Create fresh
synthetic users for a demo. Use a different JWT secret from the source system.

Set `DEMO_DATABASE_URL` privately to the local clone; its name must end in
`_demo`. Stop writers before inspecting or scrubbing it. Run:

```sh
python scripts/scrub_demo_database.py
python scripts/scrub_demo_database.py --apply-to stockfolio_demo
python scripts/scrub_demo_database.py
```

The first and last runs are count-only. Verify all listed counts are zero
after the confirmed run. Deletes are transactional. This is logical removal,
not secure disk erasure. It does not scrub the source database, retained
backups, WAL, external services, or files. For distribution, export the
sanitised logical data rather than distributing the original database files.
