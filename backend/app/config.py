from functools import lru_cache
from pathlib import Path

import yaml
from pydantic import BaseModel
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.models import ServiceConfig

BACKEND_ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", extra="ignore")

    services_config_path: str = str(BACKEND_ROOT / "config" / "services.yaml")
    health_check_timeout_seconds: float = 5.0
    cors_allow_origins: str = "http://localhost:5173"
    log_level: str = "INFO"

    @property
    def cors_origins(self) -> list[str]:
        return [origin.strip() for origin in self.cors_allow_origins.split(",") if origin.strip()]


class ServiceRegistry(BaseModel):
    services: list[ServiceConfig]


@lru_cache
def get_settings() -> Settings:
    return Settings()


def load_service_registry(path: str | None = None) -> list[ServiceConfig]:
    settings = get_settings()
    registry_path = Path(path or settings.services_config_path)
    raw = yaml.safe_load(registry_path.read_text())
    return ServiceRegistry.model_validate(raw).services
