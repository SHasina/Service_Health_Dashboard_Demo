from fastapi import APIRouter, Request, Response, status

router = APIRouter()


@router.get("/healthz")
async def liveness() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz")
async def readiness(request: Request, response: Response) -> dict[str, str]:
    services = getattr(request.app.state, "services", None)
    if not services:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "not ready"}
    return {"status": "ready"}
