import asyncio
import hmac
import os
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

import routes
from config import DATA_DIR, load_config
from db import init_db
from lock import LockManager
from logger import get_logger, new_request_id
from scheduler import cleanup_loop
from storage import ensure_bucket_dir

log = get_logger(__name__)

CONFIG_PATH = "/config/config.yaml"
PORT = 8080

# MCP server (optional — requires fastmcp)
_mcp_available = False
_mcp_app = None
try:
    from fastmcp.utilities.lifespan import combine_lifespans

    from mcp_server import mcp as _mcp_instance

    _mcp_app = _mcp_instance.http_app(path="/")
    _mcp_available = True
except ImportError:
    pass


@asynccontextmanager
async def _app_lifespan(app: FastAPI):
    cfg = load_config(CONFIG_PATH)

    os.makedirs(DATA_DIR, exist_ok=True)
    for name in cfg.buckets:
        ensure_bucket_dir(DATA_DIR, name)

    db_path = os.path.join(DATA_DIR, "hybrids3.db")
    conn = init_db(db_path)

    locks = LockManager(
        acquire_timeout=cfg.lock_acquire_timeout,
        hold_timeout=cfg.lock_hold_timeout,
        max_waiters=cfg.lock_max_waiters,
    )

    routes.config = cfg
    routes.db_conn = conn
    routes.lock_manager = locks

    global _app_config
    _app_config = cfg

    if _mcp_available:
        import mcp_server

        mcp_server.init(cfg, conn, locks)
        log.info("MCP server mounted at /mcp")

    task = asyncio.create_task(cleanup_loop(cfg, conn))

    log.info(
        "HybridS3 started",
        extra={"buckets": len(cfg.buckets)},
    )
    for name, bc in cfg.buckets.items():
        log.info(
            "bucket configured",
            extra={
                "bucket": name,
                "public": bc.public,
                "ttl_seconds": bc.ttl_seconds,
                "max_file_size_bytes": bc.max_file_size_bytes,
            },
        )

    yield

    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    conn.close()


# set during lifespan from config
_app_config = None


def _valid_mcp_token(token: str) -> bool:
    """Check token against master key and all bucket keys."""
    if not token or _app_config is None:
        return False
    cfg = _app_config
    if cfg.master_key and hmac.compare_digest(token, cfg.master_key):
        return True
    for bc in cfg.buckets.values():
        if hmac.compare_digest(token, bc.key):
            return True
    return False


class McpAuthMiddleware(BaseHTTPMiddleware):
    """Optionally protect /mcp/ with Bearer token or ?auth= query param.

    If a token is provided, it must match the master key or a bucket key.
    If no token is provided, the request passes through and per-tool auth applies.
    """

    async def dispatch(self, request: Request, call_next):  # type: ignore[override]
        if not request.url.path.startswith("/mcp"):
            return await call_next(request)
        token = ""
        auth_header = request.headers.get("authorization", "")
        if auth_header.lower().startswith("bearer "):
            token = auth_header[7:]
        if not token:
            token = request.query_params.get("auth", "")
        if token and not _valid_mcp_token(token):
            return JSONResponse({"error": "Unauthorized"}, status_code=401)
        return await call_next(request)


class RequestIdMiddleware(BaseHTTPMiddleware):
    """Assign a request ID to every request, add to response headers."""

    async def dispatch(self, request: Request, call_next):  # type: ignore[override]
        rid = new_request_id()
        response = await call_next(request)
        response.headers["X-Request-Id"] = rid
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response


if _mcp_available and _mcp_app is not None:
    app = FastAPI(
        title="HybridS3",
        lifespan=combine_lifespans(_app_lifespan, _mcp_app.lifespan),
    )
    app.mount("/mcp", _mcp_app)
else:
    app = FastAPI(title="HybridS3", lifespan=_app_lifespan)
    if not _mcp_available:
        log.warning("fastmcp not installed — MCP server disabled")

app.add_middleware(McpAuthMiddleware)
app.add_middleware(RequestIdMiddleware)
app.include_router(routes.router)

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=PORT)
