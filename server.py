"""
LIMITLESS Vanity Grinder Worker — FastAPI HTTP server.

Persistent worker running on a vast.ai RTX 4090 instance.
Accepts grind requests via POST /grind, returns AES-256-GCM encrypted keypairs.
"""

import asyncio
import os
import time

from fastapi import Depends, FastAPI, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, field_validator

from encryption import decrypt_keypair, encrypt_keypair
from grind_handler import grind_keypair

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

GRINDER_AUTH_TOKEN = os.environ.get("GRINDER_AUTH_TOKEN", "")
ENCRYPTION_KEY = os.environ.get("GRINDER_ENCRYPTION_KEY", "")
BASE58_CHARS = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

if not GRINDER_AUTH_TOKEN:
    raise RuntimeError("GRINDER_AUTH_TOKEN env var is required")
if not ENCRYPTION_KEY:
    raise RuntimeError("GRINDER_ENCRYPTION_KEY env var is required")

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="LIMITLESS Vanity Grinder Worker", docs_url=None, redoc_url=None)
security = HTTPBearer()

START_TIME = time.time()
_queue_depth = 0
_grind_semaphore = asyncio.Semaphore(1)


def _verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    if credentials.credentials != GRINDER_AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class GrindRequest(BaseModel):
    prefix: str | None = None
    suffix: str | None = None
    position: str = "start"
    max_seconds: int = 600
    request_id: str

    @field_validator("position")
    @classmethod
    def validate_position(cls, v: str) -> str:
        if v not in ("start", "end"):
            raise ValueError("position must be 'start' or 'end'")
        return v

    @field_validator("prefix", "suffix", mode="before")
    @classmethod
    def validate_base58(cls, v: str | None) -> str | None:
        if v is None:
            return v
        for ch in v:
            if ch not in BASE58_CHARS:
                raise ValueError(f"Invalid base58 character: {ch}")
        if len(v) < 1 or len(v) > 8:
            raise ValueError("Pattern must be 1-8 characters")
        return v

    @field_validator("max_seconds")
    @classmethod
    def validate_max_seconds(cls, v: int) -> int:
        if v < 1 or v > 36000:
            raise ValueError("max_seconds must be between 1 and 36000")
        return v


class GrindResponse(BaseModel):
    pubkey: str
    encrypted_keypair_b64: str
    iv_b64: str
    tag_b64: str
    grind_seconds: float
    request_id: str


class HealthResponse(BaseModel):
    status: str
    gpu_temp: int | None = None
    uptime: float
    queue_depth: int


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_gpu_temp() -> int | None:
    """Read GPU temperature from nvidia-smi."""
    import subprocess

    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return int(result.stdout.strip().split("\n")[0])
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.get("/health")
async def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        gpu_temp=_get_gpu_temp(),
        uptime=round(time.time() - START_TIME, 1),
        queue_depth=_queue_depth,
    )


@app.post("/grind", dependencies=[Depends(_verify_token)])
async def grind(req: GrindRequest) -> GrindResponse:
    global _queue_depth

    # Determine pattern
    pattern = req.prefix or req.suffix
    if not pattern:
        raise HTTPException(status_code=400, detail="Either prefix or suffix is required")

    use_prefix = req.position == "start" and req.prefix is not None
    flag = "--starts-with" if use_prefix else "--ends-with"

    _queue_depth += 1
    try:
        async with _grind_semaphore:
            loop = asyncio.get_event_loop()
            pubkey, keypair_bytes, elapsed = await loop.run_in_executor(
                None,
                grind_keypair,
                pattern,
                flag,
                req.max_seconds,
                req.request_id,
            )
    finally:
        _queue_depth -= 1

    # Encrypt keypair for transport
    ciphertext_b64, iv_b64, tag_b64 = encrypt_keypair(keypair_bytes, ENCRYPTION_KEY)

    return GrindResponse(
        pubkey=pubkey,
        encrypted_keypair_b64=ciphertext_b64,
        iv_b64=iv_b64,
        tag_b64=tag_b64,
        grind_seconds=round(elapsed, 3),
        request_id=req.request_id,
    )
