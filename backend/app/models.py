from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field, HttpUrl


class ServiceConfig(BaseModel):
    name: str
    url: HttpUrl


class ServiceHealth(BaseModel):
    name: str
    status: Literal["UP", "DOWN"]
    latency_ms: float | None = None
    detail: str | None = None


class HealthReport(BaseModel):
    services: list[ServiceHealth]
    checked_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
