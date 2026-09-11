import httpx
import respx

from app.health_checker import check_all_services, check_service
from app.models import ServiceConfig


@respx.mock
async def test_check_service_up():
    service = ServiceConfig(name="user-service", url="http://user-service.test/health")
    respx.get(str(service.url)).mock(return_value=httpx.Response(200))

    async with httpx.AsyncClient() as client:
        result = await check_service(client, service, timeout_seconds=5.0)

    assert result.status == "UP"
    assert result.detail is None
    assert result.latency_ms is not None


@respx.mock
async def test_check_service_timeout():
    service = ServiceConfig(name="order-service", url="http://order-service.test/health")
    respx.get(str(service.url)).mock(side_effect=httpx.TimeoutException("timed out"))

    async with httpx.AsyncClient() as client:
        result = await check_service(client, service, timeout_seconds=5.0)

    assert result.status == "DOWN"
    assert result.detail == "Timeout"


@respx.mock
async def test_check_service_connection_refused():
    service = ServiceConfig(name="payment-service", url="http://payment-service.test/health")
    respx.get(str(service.url)).mock(side_effect=httpx.ConnectError("refused"))

    async with httpx.AsyncClient() as client:
        result = await check_service(client, service, timeout_seconds=5.0)

    assert result.status == "DOWN"
    assert result.detail == "Connection refused"


@respx.mock
async def test_check_service_http_error_status():
    service = ServiceConfig(name="user-service", url="http://user-service.test/health")
    respx.get(str(service.url)).mock(return_value=httpx.Response(500))

    async with httpx.AsyncClient() as client:
        result = await check_service(client, service, timeout_seconds=5.0)

    assert result.status == "DOWN"
    assert result.detail == "HTTP 500"


@respx.mock
async def test_check_all_services_mixed_results(sample_services):
    respx.get(str(sample_services[0].url)).mock(return_value=httpx.Response(200))
    respx.get(str(sample_services[1].url)).mock(side_effect=httpx.TimeoutException("timed out"))
    respx.get(str(sample_services[2].url)).mock(return_value=httpx.Response(200))

    results = await check_all_services(sample_services, timeout_seconds=5.0)

    statuses = {r.name: r.status for r in results}
    assert statuses == {
        "user-service": "UP",
        "order-service": "DOWN",
        "payment-service": "UP",
    }
