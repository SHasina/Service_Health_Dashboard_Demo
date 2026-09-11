from fastapi import APIRouter, Request

from app.health_checker import check_all_services
from app.models import HealthReport

router = APIRouter()


@router.get("/api/health", response_model=HealthReport)
async def get_health(request: Request) -> HealthReport:
    services = request.app.state.services
    timeout_seconds = request.app.state.settings.health_check_timeout_seconds
    results = await check_all_services(services, timeout_seconds)
    return HealthReport(services=results)
