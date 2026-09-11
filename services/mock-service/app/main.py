import asyncio
import os

from fastapi import FastAPI, HTTPException

app = FastAPI(title="Mock Downstream Service")

MOCK_NAME = os.environ.get("MOCK_NAME", "mock-service")
MOCK_MODE = os.environ.get("MOCK_MODE", "healthy")
MOCK_DELAY_SECONDS = float(os.environ.get("MOCK_DELAY_SECONDS", "8"))


@app.get("/health")
async def health() -> dict[str, str]:
    if MOCK_MODE == "error":
        raise HTTPException(status_code=500, detail=f"{MOCK_NAME} is unhealthy")

    if MOCK_MODE == "slow":
        await asyncio.sleep(MOCK_DELAY_SECONDS)

    return {"status": "ok", "service": MOCK_NAME}
