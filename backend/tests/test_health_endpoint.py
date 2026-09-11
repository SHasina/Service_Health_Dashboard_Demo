import httpx
import respx
from fastapi.testclient import TestClient

from app.main import app


@respx.mock
def test_get_health_returns_service_statuses():
    with TestClient(app) as client:
        for service in client.app.state.services:
            respx.get(str(service.url)).mock(return_value=httpx.Response(200))

        response = client.get("/api/health")

    assert response.status_code == 200
    body = response.json()
    assert len(body["services"]) == 3
    assert all(service["status"] == "UP" for service in body["services"])
