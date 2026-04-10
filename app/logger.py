"""Centralized JSON logger with request ID tracking.

Usage:
    from logger import get_logger, get_request_id
    log = get_logger(__name__)
    log.info("something happened")
    log.warning("watch out", extra={"key": "value"})

Output (one JSON object per line):
    {"ts":"21:05:33","level":"INFO","src":"main:_app_lifespan:42","msg":"something happened"}
    {"ts":"21:05:34","level":"WARNING","src":"routes:put_object:55",
     "rid":"a1b2c3","msg":"watch out","key":"value"}
"""

from __future__ import annotations

import contextvars
import json
import logging
import sys
import uuid
from datetime import datetime
from typing import Any

# per-request ID stored in contextvars (async-safe)
_request_id: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="")


def set_request_id(rid: str) -> None:
    _request_id.set(rid)


def get_request_id() -> str:
    return _request_id.get()


def new_request_id() -> str:
    rid = uuid.uuid4().hex[:12]
    _request_id.set(rid)
    return rid


class _JSONFormatter(logging.Formatter):
    """Format log records as single-line JSON."""

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created).strftime("%H:%M:%S"),
            "level": record.levelname,
            "src": f"{record.module}:{record.funcName}:{record.lineno}",
            "msg": record.getMessage(),
        }
        rid = _request_id.get()
        if rid:
            entry["rid"] = rid
        # merge any extra keys passed via extra={...}
        for k, v in record.__dict__.items():
            if k not in _RESERVED and k not in entry:
                entry[k] = v
        if record.exc_info and record.exc_info[1]:
            entry["error"] = str(record.exc_info[1])
        return json.dumps(entry, default=str)


# standard LogRecord attributes to exclude from extras
_RESERVED = frozenset(
    {
        "name",
        "msg",
        "args",
        "created",
        "relativeCreated",
        "exc_info",
        "exc_text",
        "stack_info",
        "lineno",
        "funcName",
        "filename",
        "module",
        "levelname",
        "levelno",
        "pathname",
        "process",
        "processName",
        "thread",
        "threadName",
        "msecs",
        "message",
        "taskName",
    }
)

_configured = False


def configure_output(stream: Any = None, level: int = logging.INFO) -> None:
    """Reconfigure logging output stream."""
    if stream is None:
        stream = sys.stdout
    handler = logging.StreamHandler(stream)
    handler.setFormatter(_JSONFormatter())
    logging.root.handlers = [handler]
    logging.root.setLevel(level)


def get_logger(name: str) -> logging.Logger:
    """Get a logger that outputs JSON to stdout."""
    global _configured
    if not _configured:
        configure_output(sys.stdout)
        _configured = True
    return logging.getLogger(name)
