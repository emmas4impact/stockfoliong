"""Versioned research comparisons using observations actually received from the feed."""

import hashlib
import json
import math
from datetime import datetime, timedelta, timezone
from statistics import median

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert

from .models import FundamentalObservation, StockAnalysis
from .instrument_reference import instrument_class

MODEL_VERSION = "sector-pe-v3"
MAX_AGE = timedelta(days=7)
MIN_PEERS = 3
DISCLAIMER = "Research information only, not financial advice. Contact your broker for detailed analysis."


def fingerprint(payload):
    return hashlib.sha256(json.dumps(payload, sort_keys=True, allow_nan=False).encode()).hexdigest()


def finite_number(value):
    try:
        number = float(value)
    except (ValueError, TypeError, OverflowError):
        return None
    return number if math.isfinite(number) else None


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def parse_timestamp(value):
    if isinstance(value, datetime):
        return utc(value)
    if not isinstance(value, str):
        return None
    try:
        return utc(datetime.fromisoformat(value))
    except ValueError:
        return None


def data_freshness(received_at, updated_at, now):
    received, updated = parse_timestamp(received_at), parse_timestamp(updated_at)
    now = utc(now)
    if any(value is not None and not now - MAX_AGE <= value <= now for value in (received, updated)):
        return "stale"
    return "current" if received is not None and updated is not None else "unknown"


def pe_freshness(observation, now):
    inputs = observation.inputs
    metrics = inputs.get("fundamentals")
    # An unrelated valuation timestamp must not certify a stock-list P/E.
    if not isinstance(metrics, dict) or finite_number(metrics.get("pe_ratio")) is None:
        return "unknown"
    if finite_number(metrics["pe_ratio"]) != finite_number(inputs.get("pe_ratio")):
        return "unknown"
    received = inputs.get("fundamentals_received_at", observation.observed_at)
    status = data_freshness(received, metrics.get("updated_at"), now)
    if not utc(now) - MAX_AGE <= utc(observation.observed_at) <= utc(now):
        return "stale"
    return status


def record_observation(db, stock_data, observed_at=None):
    # Use this response, not Stock's carried-forward values from earlier syncs.
    source = stock_data.get("source")
    if source not in {"ngxpulse", "ngx_doclib"}:
        return
    observed_at = observed_at or datetime.now(timezone.utc)
    inputs = {
        "price": finite_number(stock_data.get("last_price")),
        "pe_ratio": finite_number(stock_data.get("pe_ratio")),
        "sector": (stock_data.get("sector") or "").strip().casefold() or None,
        "pe_basis": "unspecified_by_feed",
        "reporting_period": None,
        "published_at": None,
    }
    if "fundamentals" in stock_data:
        inputs["fundamentals"] = stock_data["fundamentals"]
        inputs["fundamentals_source"] = "kobo_fundamentals"
        if stock_data.get("fundamentals_received_at"):
            inputs["fundamentals_received_at"] = stock_data["fundamentals_received_at"]
        if stock_data["fundamentals"]["pe_ratio"] is not None:
            inputs["pe_basis"] = "trailing"
    previous = db.scalar(select(FundamentalObservation).where(
        FundamentalObservation.stock_symbol == stock_data["symbol"],
    ).order_by(FundamentalObservation.observed_at.desc(), FundamentalObservation.id.desc()).limit(1))
    if (previous is not None and previous.source == source and previous.inputs == inputs
            and utc(previous.observed_at).date() == utc(observed_at).date()):
        return
    key = fingerprint([stock_data["symbol"], source, utc(observed_at).isoformat(), inputs,
                       previous.observation_key if previous else None])
    db.execute(insert(FundamentalObservation).values(
        observation_key=key, stock_symbol=stock_data["symbol"],
        observed_at=observed_at, source=source, inputs=inputs,
    ).on_conflict_do_nothing(index_elements=["observation_key"]))


def latest_observations(db):
    ranked = select(
        FundamentalObservation.id,
        func.row_number().over(
            partition_by=FundamentalObservation.stock_symbol,
            order_by=(FundamentalObservation.observed_at.desc(), FundamentalObservation.id.desc()),
        ).label("position"),
    ).subquery()
    return list(db.scalars(select(FundamentalObservation).join(
        ranked, ranked.c.id == FundamentalObservation.id,
    ).where(ranked.c.position == 1)))


def score_observation(target, universe, now=None, *, legacy_mixed=False):
    now = now or datetime.now(timezone.utc)
    inputs = target.inputs
    pe = finite_number(inputs.get("pe_ratio"))
    sector = inputs.get("sector")
    freshness = pe_freshness(target, now)
    fresh = freshness == "current"
    eligible_target = legacy_mixed or instrument_class(target.stock_symbol) == "company_share"
    peers = [row for row in universe if (
        eligible_target and row.stock_symbol != target.stock_symbol and sector
        and row.inputs.get("sector") == sector and row.source == target.source
        and (legacy_mixed or instrument_class(row.stock_symbol) == "company_share")
        and pe_freshness(row, now) == "current"
        and (finite_number(row.inputs.get("pe_ratio")) or 0) > 0
    )]
    values = [float(row.inputs["pe_ratio"]) for row in peers]
    reasons = []
    score = None
    sector_pe = median(values) if len(values) >= MIN_PEERS else None
    if freshness == "stale":
        reasons.append("The observation, fundamentals receipt or provider update is older than seven days or in the future.")
    elif freshness == "unknown":
        reasons.append("P/E freshness cannot be confirmed from matching provider fundamentals and valid receipt/update timestamps.")
    if pe is None or pe <= 0:
        reasons.append("A positive P/E is unavailable; zero or negative P/E is not scored as cheap.")
    if not sector:
        reasons.append("Sector classification is unavailable.")
    if not eligible_target:
        reasons.append("Not scored: this comparison is for verified company shares only.")
    elif len(peers) < MIN_PEERS:
        reasons.append("Insufficient peers: at least three same-sector peers from the same source with confirmed current positive P/E are required.")
    if fresh and pe is not None and pe > 0 and sector_pe is not None:
        score = round(100 * sum(1 if other > pe else 0.5 if other == pe else 0 for other in values) / len(values), 2)
        reasons.append("Valuation is the percentile of sector peers with a higher P/E, with half weight for ties.")
    return {
        "symbol": target.stock_symbol, "model_version": "sector-pe-v2" if legacy_mixed else MODEL_VERSION,
        "observed_at": utc(target.observed_at).isoformat(), "source": target.source,
        "inputs": inputs, "stale": not fresh, "freshness": freshness,
        "scores": {"valuation": score, "growth": None, "dividend": None,
                   "financial_strength": None, "momentum": None, "overall": None},
        "sector_pe_median": sector_pe, "peer_count": len(peers),
        "peer_inputs": [{"symbol": row.stock_symbol, "observation_id": row.id,
                         "pe_ratio": row.inputs["pe_ratio"],
                         "provider_updated_at": row.inputs["fundamentals"].get("updated_at"),
                         "received_at": row.inputs.get("fundamentals_received_at", utc(row.observed_at).isoformat())}
                        for row in sorted(peers, key=lambda row: row.stock_symbol)],
        "coverage": {"scored_components": int(score is not None), "total_components": 5},
        "reasons": reasons,
        "limitations": ["Financial reporting dates are unknown. Stock-list P/E has an unspecified basis.",
                        "Observed date is when we received data, not its publication date.",
                        "Relative P/E is an experimental comparison, not a forecast or probability of profit.",
                        "The valuation score uses only P/E; other fundamentals are not scored."],
        "disclaimer": DISCLAIMER,
    }


def save_analysis(db, target, universe, now=None):
    now = now or datetime.now(timezone.utc)
    result = score_observation(target, universe, now)
    key = fingerprint([target.id, result])
    result["generated_at"] = utc(now).isoformat()
    db.execute(insert(StockAnalysis).values(
        analysis_key=key, stock_symbol=target.stock_symbol, observation_id=target.id,
        model_version=MODEL_VERSION, generated_at=now, result=result,
    ).on_conflict_do_nothing(index_elements=["analysis_key"]))
    return db.scalar(select(StockAnalysis).where(StockAnalysis.analysis_key == key)).result


def archive_sync_analysis(db):
    universe = latest_observations(db)
    now = datetime.now(timezone.utc)
    for target in universe:
        save_analysis(db, target, universe, now)
