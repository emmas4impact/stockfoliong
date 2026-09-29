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

Observations include price, P/E, sector, source and receipt time. Reporting period,
publication time and P/E basis are explicitly unknown in the current adapter.
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

## Next milestone

Confirm NGXPulse's historical fundamentals fields and commercial storage rights.
Add reporting periods, publication dates, EPS basis, financial statements and
corporate actions before introducing growth/dividend scores or historical outcome
evaluation. Then expose the analysis and its coverage in Flutter, followed by
subscription entitlements and ads.
