import pytest

from app.models import ServiceConfig

SAMPLE_SERVICES = [
    ServiceConfig(name="user-service", url="http://user-service.test/health"),
    ServiceConfig(name="order-service", url="http://order-service.test/health"),
    ServiceConfig(name="payment-service", url="http://payment-service.test/health"),
]


@pytest.fixture
def sample_services() -> list[ServiceConfig]:
    return SAMPLE_SERVICES
