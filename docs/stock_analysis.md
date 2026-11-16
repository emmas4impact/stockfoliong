# Stock analysis: first milestone

The authenticated API now exposes:

- `GET /stocks/{symbol}/analysis`: current experimental sector P/E comparison.
- `GET /stocks/{symbol}/analysis/history?limit=30`: saved analysis results, newest first (maximum 100).

Unknown symbols return 404. A known stock without an observation returns 503
until a successful stock sync. The endpoints only read PostgreSQL; they do not
call the provider or calculate anything in Flutter.

## Storage and deployment

The existing startup `Base.metadata.create_all` creates two new tables:
`fundamental_observations` and `stock_analyses`. No existing columns are changed.
Deploy the backend, then run the existing stock sync or allow its scheduled run.
Every successful sync captures the normalized source response before any
carried-forward Stock fields can contaminate it. Identical observations on the
same UTC day are skipped; changes and subsequent days are retained. No retention
deletion is configured for either table.

When the live stock list comes from NGXPulse, the sync reuses a bulk fundamentals
batch saved in the database for 24 hours. On a cold or expired cache it requests
`https://koboterminal.com/api/ngxdata/fundamentals`, using the existing
`NGXPULSE_API_KEY` in the request header. It joins by symbol, not list position.
A match stores metrics, provider `updated_at` and scalar `extra` fields in
`inputs.fundamentals`. A numeric trailing P/E from that endpoint takes precedence
over stock-list P/E. Forward P/E is never substituted. Unmatched quotes still sync;
a failed fundamentals request is logged and does not stop price ingestion.
After a failure, the sync waits at least one hour before retrying. Financial
detail reads continue serving the last usable valuation for each symbol.
The sync result message reports matches or the provider error. No database migration
or Flutter rebuild is required for this enrichment.

Observations include price, P/E, sector, source and receipt time. Reporting period
and publication time are unknown; stock-list P/E has an unspecified basis.
Receipt time does not prove when earnings were published or that they are fresh.
Old Stock rows are deliberately not backfilled as historical fundamentals.

The sync also archives analysis with its model version, target inputs and peer
observation IDs/values. Unchanged model inputs/results reuse the existing record.
These records provide prospective evidence from deployment onward, not a
retrospective track record. They are research datasets; do not expose any user
portfolio or personal information.

## Model `sector-pe-v1`

- Same normalized sector and provider; exclude the target stock.
- Only positive finite P/E values and observations received within seven days.
- At least three eligible peers; otherwise valuation is null.
- Valuation = 100 * (peers with higher P/E + half of tied peers) / peer count.
- Return sector median P/E, component coverage, inputs, reasons and limitations.
- Negative/zero P/E is not treated as undervaluation.
- Overall, growth, dividend, financial strength and momentum scores remain null.

This model has not been backtested and is not a price prediction, probability of
profit or buy/sell recommendation. Its numeric score is only a relative ranking.
The existing `/market/ideas` model and Flutter panel are unchanged in this milestone.

## Validation

Using Python 3.12 with backend dependencies installed:

```sh
python -m unittest discover -s backend/tests -v
```

The tests use isolated SQLite tables and cover sector/source filtering, stale
observations, missing/negative P/E, insufficient peers, repeated ingestion and
immutable analysis storage. Production PostgreSQL deployment still requires a
smoke check after migration/startup and a successful provider sync.

### Measure coverage on the hosted API

From the repository root, run the read-only check with a normal app account:

```sh
python3 scripts/check_analysis_coverage.py https://ngx-api.up.railway.app
```

Enter credentials at the local prompts, not in chat or the command line. The
script checks each listed symbol sequentially against the authenticated API;
it requires no redeploy. It reports numeric valuations (including zero) as a
percentage of **all listed stocks**, separates missing observations from missing
scores, and checks saved history for up to three sectors. Reasons can overlap.
This is a rolling read, not a transactionally consistent snapshot during a sync.
HTTP failures other than the known missing-observation response abort the check.

Only to deliberately run a write on the specified backend, add `--sync` and
log in with an admin account. This requests one stock sync without chart-history
backfill and rejects cached or seeded results. Otherwise the existing scheduled
sync is sufficient. Assess coverage by sector before exposing the score in Flutter.

## Read-only data quality audit

Admins can request `GET /admin/analysis/data-quality` or run:

```sh
python3 scripts/check_analysis_coverage.py https://ngx-api.up.railway.app --data-quality
```

This requires the updated backend and an admin login. It performs no provider
requests or database writes. Do not add `--sync` unless you explicitly intend to
refresh the database before auditing it. The original checker without this flag
still works with a normal account.

The report includes all database symbols, per-sector coverage and per-symbol
issues: missing observations, unavailable P/E scores, stale/unknown valuations,
missing reporting/publication dates, invalid statement records, comparable
revenue/EPS Y/Y pairs, and the extent of saved prices and analysis history.
Zero P/E scores count as covered. Latest usable valuations remain visible even
after a newer quote-only observation. Counters use all listed symbols as the
denominator; issue counts overlap. An empty database has null percentages.

This audit does not certify accounting accuracy or forecast readiness. Statement
checks use the existing reviewed-input validator and period comparability rules;
Y/Y comparisons can refer to older periods. Saved history is not a backtest.
Provider update timestamps must not be mistaken for earnings publication dates.
The report is a rolling read, not a transactionally frozen snapshot. No schema
migration, scoring-rule change, or mobile/web rebuild is needed.

## Next milestone

Confirm NGXPulse's historical fundamentals fields and commercial storage rights.
Add reporting periods, publication dates, EPS basis, financial statements and
corporate actions before introducing growth/dividend scores or historical outcome
evaluation. Then expose the analysis and its coverage in Flutter, followed by
subscription entitlements and ads.
