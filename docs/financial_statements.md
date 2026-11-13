# Financial statements

Portfolio and stock details expose `financials` on the existing detail response.
The Flutter view is shared by web, Android and iOS. Valuations come from the latest
saved Kobo fundamentals observation; no provider request or PDF extraction runs
when opening the view. P/B and P/E are multiples, not currency amounts. Provider
EPS has no currency/period metadata and is displayed as provider units only.

Annual/interim figures require reviewed structured data. Disclosure metadata is
not a statement dataset. Until reviewed records exist, the view shows an empty
state and links to available financial reports, never invented figures.

## Import

`PUT /admin/stocks/{symbol}/financial-statements` requires a superuser bearer token.
Send one reviewed statement per request. Reimporting the same fiscal year,
quarter, basis and scope replaces that record (for example, a restatement).
Retain original filings outside the app for audit purposes. The reviewer user ID
and update timestamp are stored. This is not a versioned filing archive.

Fields:

- `fiscal_year`: integer, and `quarter`: 1–4 for interim reports, null for annual.
- `basis`: `annual`, `standalone_quarter`, or `year_to_date`. Never label nine-month
  results as a standalone Q3. No automatic YTD-to-quarter subtraction is performed.
- `period_start`, `period_end`: ISO dates for the reporting interval.
- `currency`: three-letter code; `scope`: `consolidated` or `company`.
- `audited`: boolean; `reviewed`: must be true after checking against the filing.
- `source_url`, `source_title`: original filing link and descriptive title.
- `metrics`: optional numeric `revenue`, `gross_profit`, `ebit`,
  `profit_before_tax`, `net_profit`, `eps`, `total_assets`, `total_liabilities`,
  `total_equity`, `ordinary_equity`. At least one value is required.

All monetary figures must be in **full currency units**, not thousands or millions.
EPS is currency per ordinary share. Use null/omit for unavailable or inapplicable
metrics. Do not relabel bank gross earnings as gross profit or invent EBIT for
bank groups. Ordinary equity must exclude non-controlling and preference interests.
Only compare the same reporting scope, currency, fiscal period and duration.
Negative/zero prior-year baselines show unavailable Y/Y rather than misleading growth.
Liability growth is displayed neutrally, not as automatically good news.

## Deployment

The additive `financial_statements` table is created by the existing startup
`Base.metadata.create_all` routine. There are no new required environment variables,
keys, data rewrites, or changes to holdings/authentication. Deploy the API before
the new client. Older API responses are supported by the client with empty financials.
Back up the database before deployment as usual. This feature does not populate
financial statement records automatically or modify a production database during tests.

Current valuations stay separate from statement period selection: a provider
snapshot is not a historical period-end P/B. If deriving P/B later, require
date-compatible ordinary equity, outstanding shares (not EPS weighted-average
shares), price, and adjustments for subsequent share issues. Do not silently mix
those dates or calculate a meaningful P/B for non-positive book equity.

## Verification

Install `requirements-test.txt`, then run `python -m unittest discover -s backend/tests`.
The backend tests use temporary in-memory SQLite databases. Run `flutter test`
and `flutter analyze` from `flutter_app` for the shared mobile/web client.
