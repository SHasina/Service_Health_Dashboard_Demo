import asyncio
import logging
import time

import httpx

from app.models import ServiceConfig, ServiceHealth

logger = logging.getLogger(__name__)


async def check_service(
    client: httpx.AsyncClient, service: ServiceConfig, timeout_seconds: float
) -> ServiceHealth:
    start = time.perf_counter()
    try:
        response = await client.get(str(service.url))
        latency_ms = (time.perf_counter() - start) * 1000
        response.raise_for_status()
        return ServiceHealth(name=service.name, status="UP", latency_ms=round(latency_ms, 1))
    except httpx.TimeoutException:
        logger.warning("Health check timed out", extra={"extra_fields": {"service": service.name}})
        return ServiceHealth(name=service.name, status="DOWN", detail="Timeout")
    except httpx.ConnectError:
        logger.warning(
            "Health check connection refused", extra={"extra_fields": {"service": service.name}}
        )
        return ServiceHealth(name=service.name, status="DOWN", detail="Connection refused")
    except httpx.HTTPStatusError as exc:
        logger.warning(
            "Health check returned error status",
            extra={
                "extra_fields": {"service": service.name, "status_code": exc.response.status_code}
            },
        )
        return ServiceHealth(
            name=service.name, status="DOWN", detail=f"HTTP {exc.response.status_code}"
        )
    except httpx.RequestError as exc:
        logger.warning(
            "Health check request failed",
            extra={"extra_fields": {"service": service.name, "error": str(exc)}},
        )
        return ServiceHealth(name=service.name, status="DOWN", detail="Request failed")


async def check_all_services(
    services: list[ServiceConfig], timeout_seconds: float
) -> list[ServiceHealth]:
    async with httpx.AsyncClient(timeout=timeout_seconds) as client:
        results = await asyncio.gather(
            *(check_service(client, service, timeout_seconds) for service in services)
        )
    return list(results)
