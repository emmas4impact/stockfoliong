"""Read-only coverage audit of stored market data, not an investment rating."""

from collections import Counter, defaultdict
from datetime import datetime, timezone

from pydantic import ValidationError
from sqlalchemy import func, select

from .analysis import latest_observations, score_observation, utc
from .financials import StatementInput, has_valuation, statement_history, valuation_snapshot
from .models import FinancialStatement, FundamentalObservation, Stock, StockAnalysis, StockPrice


def _dated(value):
    if not isinstance(value, str):
        return None
    try:
        return utc(datetime.fromisoformat(value))
    except ValueError:
        return None


def data_quality_report(db, now=None):
    now = utc(now or datetime.now(timezone.utc))
    stocks = list(db.scalars(select(Stock).order_by(Stock.symbol)))
    universe = latest_observations(db)
    latest = {row.stock_symbol: row for row in universe}
    obs = FundamentalObservation
    ranked = select(obs.id, func.row_number().over(
        partition_by=obs.stock_symbol, order_by=(obs.observed_at.desc(), obs.id.desc()),
    ).label("position")).where(has_valuation()).subquery()
    valuations = {row.stock_symbol: row for row in db.scalars(
        select(obs).join(ranked, ranked.c.id == obs.id).where(ranked.c.position == 1)
    )}
    statements = defaultdict(list)
    for row in db.scalars(select(FinancialStatement)):
        statements[row.stock_symbol].append(row)
    prices = {row[0]: row for row in db.execute(select(
        StockPrice.stock_symbol, func.count(), func.min(StockPrice.trade_date),
        func.max(StockPrice.trade_date),
    ).group_by(StockPrice.stock_symbol))}
    analyses = {row[0]: row for row in db.execute(select(
        StockAnalysis.stock_symbol, func.count(), func.min(StockAnalysis.generated_at),
        func.max(StockAnalysis.generated_at),
    ).group_by(StockAnalysis.stock_symbol))}

    rows = []
    issue_counts = Counter()
    sectors = defaultdict(lambda: {"listed": 0, "pe_scored": 0, "current_pe_pb": 0,
                                   "with_reviewed_statements": 0})
    for stock in stocks:
        issues = set()
        observation = latest.get(stock.symbol)
        result = score_observation(observation, universe, now) if observation else None
        if observation is None:
            issues.add("missing_observation")
        elif result["stale"]:
            issues.add("stale_or_future_observation")
        scored = result is not None and result["scores"]["valuation"] is not None
        if not scored:
            issues.add("pe_score_unavailable")

        valuation_row = valuations.get(stock.symbol)
        snapshot = None
        if valuation_row is not None:
            try:
                snapshot = valuation_snapshot(valuation_row, now)
            except (TypeError, ValueError, OverflowError):
                issues.add("invalid_valuation_metadata")
        if snapshot is None:
            issues.add("missing_valuation")
        elif snapshot.freshness != "current":
            issues.add("valuation_" + snapshot.freshness)
        positive_pe_pb = snapshot is not None and (snapshot.pe_ratio or 0) > 0 and (snapshot.pb_ratio or 0) > 0
        if not positive_pe_pb:
            issues.add("positive_pe_pb_unavailable")

        # Provider update and receipt timestamps are not earnings publication dates.
        inputs = observation.inputs if observation else {}
        reporting_period = _dated(inputs.get("reporting_period"))
        published = _dated(inputs.get("published_at"))
        if reporting_period is None:
            issues.add("missing_or_invalid_reporting_period")
        elif reporting_period > now:
            issues.add("future_reporting_period")
        if published is None:
            issues.add("missing_or_invalid_publication_date")
        elif published > now:
            issues.add("future_publication_date")
        if reporting_period and published and published < reporting_period:
            issues.add("publication_before_period_end")
        if inputs.get("pe_basis") not in {"trailing", "forward"}:
            issues.add("unknown_pe_basis")

        valid_statements = []
        invalid_statements = 0
        for record in statements[stock.symbol]:
            try:
                statement = StatementInput.model_validate(record.payload)
                if statement.storage_key != record.period_key:
                    raise ValueError("Statement key does not match its reporting period")
                valid_statements.append(statement)
            except (ValidationError, ValueError, TypeError):
                invalid_statements += 1
        if invalid_statements:
            issues.add("invalid_statement_records")
        if not valid_statements:
            issues.add("missing_reviewed_statements")
        history = statement_history(valid_statements)
        comparisons = {metric: sum(row.yoy.get(metric) is not None for row in history)
                       for metric in ("revenue", "eps")}
        if not all(comparisons.values()):
            issues.add("incomplete_growth_comparisons")
        price_history = prices.get(stock.symbol)
        analysis_history = analyses.get(stock.symbol)
        if price_history is None:
            issues.add("missing_price_history")
        if analysis_history is None:
            issues.add("missing_analysis_history")
        current_pe_pb = positive_pe_pb and snapshot.freshness == "current"
        sector = (stock.sector or "").strip().casefold() or "(unknown sector)"
        counts = sectors[sector]
        counts["listed"] += 1
        counts["pe_scored"] += int(scored)
        counts["current_pe_pb"] += int(current_pe_pb)
        counts["with_reviewed_statements"] += int(bool(valid_statements))
        issue_counts.update(issues)
        rows.append({
            "symbol": stock.symbol, "sector": sector,
            "pe_scored": scored, "pe_score_reasons": result["reasons"] if result and not scored else [],
            "observed_at": utc(observation.observed_at).isoformat() if observation else None,
            "valuation": snapshot.model_dump(mode="json") if snapshot else None,
            "current_positive_pe_pb": current_pe_pb,
            "reporting_period": inputs.get("reporting_period"), "published_at": inputs.get("published_at"),
            "pe_basis": inputs.get("pe_basis"),
            "statements": {"valid": len(valid_statements), "invalid": invalid_statements,
                           "latest_period_end": history[0].period_end.isoformat() if history else None,
                           "comparable_yoy_pairs": comparisons},
            "price_history": {"rows": price_history[1], "first_date": price_history[2].isoformat(),
                              "last_date": price_history[3].isoformat()} if price_history else None,
            "analysis_history": {"rows": analysis_history[1], "first_generated_at": utc(analysis_history[2]).isoformat(),
                                 "last_generated_at": utc(analysis_history[3]).isoformat()} if analysis_history else None,
            "issues": sorted(issues),
        })
    total = len(rows)
    def coverage(count):
        return {"count": count, "percent": round(100 * count / total, 1) if total else None}
    return {
        "generated_at": now.isoformat(), "listed": total,
        "coverage": {
            "pe_scored": coverage(sum(row["pe_scored"] for row in rows)),
            "current_positive_pe_pb": coverage(sum(row["current_positive_pe_pb"] for row in rows)),
            "reviewed_statements": coverage(sum(row["statements"]["valid"] > 0 for row in rows)),
            "revenue_and_eps_yoy": coverage(sum(all(row["statements"]["comparable_yoy_pairs"].values()) for row in rows)),
            "saved_analysis": coverage(sum(row["analysis_history"] is not None for row in rows)),
        },
        "issues_may_overlap": dict(sorted(issue_counts.items())),
        "by_sector": dict(sorted(sectors.items())), "stocks": rows,
        "limitations": [
            "Coverage uses every stock record in this database, not a verified equities-only universe.",
            "Provider update and receipt dates do not establish earnings publication dates.",
            "Statement validation checks structure and comparability, not independent accounting accuracy.",
            "Available Y/Y pairs may be historical; their latest reporting date is shown separately.",
            "Saved analyses and prices do not constitute a backtest or a validated prediction model.",
            "This is a read-only rolling audit; a concurrent sync can change data between queries.",
        ],
    }
