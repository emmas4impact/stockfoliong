"""Reviewed statements and explicitly dated provider valuations, never PDF guesses."""

from datetime import date, datetime, timedelta, timezone
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, FiniteFloat, HttpUrl, model_validator
from sqlalchemy import select

from .analysis import finite_number, utc
from .models import FinancialStatement, FundamentalObservation


class StatementMetrics(BaseModel):
    model_config = ConfigDict(extra="forbid")
    revenue: FiniteFloat | None = None
    gross_profit: FiniteFloat | None = None
    ebit: FiniteFloat | None = None
    profit_before_tax: FiniteFloat | None = None
    net_profit: FiniteFloat | None = None
    eps: FiniteFloat | None = None
    total_assets: FiniteFloat | None = Field(default=None, ge=0)
    total_liabilities: FiniteFloat | None = Field(default=None, ge=0)
    total_equity: FiniteFloat | None = None
    ordinary_equity: FiniteFloat | None = None


class StatementInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    fiscal_year: int = Field(ge=1900, le=2200)
    quarter: int | None = Field(default=None, ge=1, le=4)
    basis: Literal["annual", "standalone_quarter", "year_to_date"]
    period_start: date
    period_end: date
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    scope: Literal["consolidated", "company"] = "consolidated"
    audited: bool
    source_url: HttpUrl
    source_title: str = Field(min_length=1, max_length=500)
    metrics: StatementMetrics
    reviewed: Literal[True]

    @model_validator(mode="after")
    def check_period(self):
        if self.period_end <= self.period_start or self.period_end > date.today():
            raise ValueError("A completed reporting period is required")
        if (self.basis == "annual") != (self.quarter is None):
            raise ValueError("Annual statements have no quarter; interim statements require one")
        days = (self.period_end - self.period_start).days + 1
        if self.basis == "standalone_quarter" and not 70 <= days <= 105:
            raise ValueError("Standalone quarter must cover approximately three months, not YTD")
        if self.basis == "year_to_date" and not self.quarter * 90 - 20 <= days <= self.quarter * 92 + 20:
            raise ValueError("YTD duration does not match the fiscal quarter")
        if not any(v is not None for v in self.metrics.model_dump().values()):
            raise ValueError("At least one reviewed financial metric is required")
        return self

    @property
    def storage_key(self):
        return f"{self.fiscal_year}:{self.quarter or 0}:{self.basis}:{self.scope}"


class StatementOut(StatementInput):
    period_key: str
    yoy: dict[str, float | None]


class ValuationOut(BaseModel):
    source: str = "Kobo fundamentals"
    observed_at: datetime
    provider_updated_at: datetime | None = None
    freshness: Literal["current", "stale", "unknown"]
    pb_ratio: float | None = None
    pe_ratio: float | None = None
    eps: float | None = None
    # The provider does not identify an EPS reporting period or historical ratio date.
    period_basis: str = "unspecified_by_provider"


class FinancialsOut(BaseModel):
    valuation: ValuationOut | None = None
    statements: list[StatementOut] = Field(default_factory=list)


def valuation_snapshot(observation, now=None):
    if observation is None:
        return None
    metrics = observation.inputs.get("fundamentals")
    if not isinstance(metrics, dict):
        return None
    now = now or datetime.now(timezone.utc)
    updated = None
    try:
        updated = datetime.fromisoformat(metrics.get("updated_at") or "")
        updated = utc(updated)
    except (TypeError, ValueError):
        pass
    freshness = "unknown"
    if updated is not None:
        freshness = "current" if now - timedelta(days=7) <= updated <= now else "stale"
    observed = utc(datetime.fromisoformat(observation.inputs["fundamentals_received_at"])) if (
        observation.inputs.get("fundamentals_received_at")
    ) else utc(observation.observed_at)
    if not now - timedelta(days=7) <= observed <= now:
        freshness = "stale"
    return ValuationOut(
        observed_at=observed, provider_updated_at=updated,
        freshness=freshness,
        **{key: finite_number(metrics.get(key)) for key in ("pb_ratio", "pe_ratio", "eps")},
    )


def statement_history(statements):
    statements = sorted(statements, key=lambda s: (s.period_end, s.storage_key), reverse=True)
    results = []
    for statement in statements:
        previous = next((s for s in statements if (
            s.fiscal_year == statement.fiscal_year - 1 and s.quarter == statement.quarter
            and s.basis == statement.basis and s.scope == statement.scope
            and s.currency == statement.currency
            and abs((statement.period_end - statement.period_start).days
                    - (s.period_end - s.period_start).days) <= 7
            and abs((statement.period_end - s.period_end).days - 365) <= 7
        )), None)
        yoy = {}
        for key, value in statement.metrics.model_dump().items():
            baseline = getattr(previous.metrics, key) if previous else None
            # Negative/zero baselines are not meaningful percentage-growth comparisons.
            growth = finite_number((value / baseline - 1) * 100) if (
                value is not None and baseline is not None and baseline > 0
            ) else None
            yoy[key] = round(growth, 2) if growth is not None else None
        results.append(StatementOut(**statement.model_dump(), period_key=statement.storage_key, yoy=yoy))
    return results


def get_financials(db, symbol):
    # A newer quote-only observation must not hide a previous successful valuation.
    metrics = FundamentalObservation.inputs["fundamentals"]
    observation = db.scalar(select(FundamentalObservation).where(
        FundamentalObservation.stock_symbol == symbol,
        (metrics["pb_ratio"].as_string().is_not(None)
         | metrics["pe_ratio"].as_string().is_not(None)
         | metrics["eps"].as_string().is_not(None)),
    ).order_by(FundamentalObservation.observed_at.desc(), FundamentalObservation.id.desc()).limit(1))
    rows = db.scalars(select(FinancialStatement).where(FinancialStatement.stock_symbol == symbol))
    statements = [StatementInput.model_validate(row.payload) for row in rows]
    return FinancialsOut(valuation=valuation_snapshot(observation), statements=statement_history(statements))
