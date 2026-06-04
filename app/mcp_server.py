"""MCP server for HybridS3 via Streamable HTTP transport.

Exposes object storage operations as MCP tools so AI agents can
upload, download, list, and delete objects. Mounted at /mcp on the
main HTTP server.
"""

from __future__ import annotations

import base64
import sqlite3
import uuid
from typing import Any

from fastmcp import FastMCP
from mcp.types import ToolAnnotations

from auth import check_bearer
from config import DATA_DIR, AppConfig
from lock import LockHoldTimeout, LockManager, LockOverloaded, LockTimeout
from db import delete_object_meta, get_object_meta, list_objects_meta, upsert_object
from logger import get_logger
from mimetype import detect as detect_mimetype
from storage import delete_file, finalize_file, read_file, write_path

log = get_logger(__name__)

# max bytes for MCP download (50MB) — larger files should use HTTP
MCP_MAX_DOWNLOAD_BYTES = 50 * 1024 * 1024

mcp = FastMCP(
    "hybrids3",
    instructions=(
        "S3-compatible object storage. Upload, download, list, and delete "
        "files in configured buckets. Use list_buckets first to discover "
        "available buckets and their settings. Each bucket has a key for "
        "write access — pass it as auth_key. Public buckets allow reads "
        "without auth_key. Private buckets require auth_key for all operations."
    ),
    mask_error_details=True,
)

# wired up by main.py at startup
_config: AppConfig = None  # type: ignore[assignment]
_db: sqlite3.Connection = None  # type: ignore[assignment]
_locks: LockManager = None  # type: ignore[assignment]


def init(config: AppConfig, db_conn: sqlite3.Connection, locks: LockManager) -> None:
    global _config, _db, _locks
    _config = config
    _db = db_conn
    _locks = locks


def _lock_err(exc: Exception) -> dict[str, Any]:
    if isinstance(exc, LockOverloaded):
        return {"error": "Too many concurrent requests for this object"}
    return {"error": "Lock timed out — try again"}


def _check_bucket(bucket: str) -> dict[str, Any] | None:
    if bucket not in _config.buckets:
        return {"error": f"Bucket '{bucket}' does not exist"}
    return None


def _check_key(bucket: str, key: str) -> bool:
    return check_bearer(_config, bucket, key)


@mcp.tool(annotations=ToolAnnotations(idempotentHint=True))
async def upload_object(
    bucket: str,
    key: str,
    content: str,
    auth_key: str,
    content_type: str = "",
    encoding: str = "utf-8",
) -> dict[str, Any]:
    """Upload content to an object in a bucket.

    Args:
        bucket: The bucket name.
        key: The object key (path). Supports nested paths like "dir/file.txt".
        content: The content to upload. For binary data, base64-encode it
            and set encoding="base64".
        auth_key: The bucket key or master key for authentication.
        content_type: MIME type. Auto-detected from content and file extension
            if not provided.
        encoding: "utf-8" (default) for text, "base64" for binary data.
    """
    err = _check_bucket(bucket)
    if err:
        return err
    if not _check_key(bucket, auth_key):
        return {"error": f"Bucket '{bucket}' does not exist"}

    bc = _config.buckets[bucket]

    if encoding == "base64":
        try:
            data = base64.b64decode(content)
        except Exception:
            return {"error": "Invalid base64 content"}
    else:
        data = content.encode("utf-8")

    if bc.max_file_size_bytes > 0 and len(data) > bc.max_file_size_bytes:
        return {"error": f"File exceeds maximum size of {bc.max_file_size_bytes} bytes"}

    try:
        dest = write_path(DATA_DIR, bucket, key)
    except ValueError:
        return {"error": "Invalid object key"}

    try:
        async with _locks.write(bucket, key):
            tmp_path = dest.with_suffix(f".tmp.{uuid.uuid4().hex[:8]}")
            try:
                tmp_path.write_bytes(data)
                tmp_path.rename(dest)
            except OSError:
                tmp_path.unlink(missing_ok=True)
                return {"error": "Storage error"}

            size, etag = finalize_file(dest)

            if not content_type:
                content_type = detect_mimetype(key, data[:8192])

            try:
                upsert_object(_db, bucket, key, content_type, size, etag, bc.ttl_seconds)
            except Exception:
                dest.unlink(missing_ok=True)
                return {"error": "Database error"}

            log.info(
                "MCP PUT",
                extra={"bucket": bucket, "key": key, "size": size, "content_type": content_type},
            )
            return {"ok": True, "size": size, "etag": etag, "content_type": content_type}
    except (LockTimeout, LockHoldTimeout, LockOverloaded) as exc:
        return _lock_err(exc)


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def download_object(
    bucket: str,
    key: str,
    auth_key: str = "",
    encoding: str = "utf-8",
) -> dict[str, Any]:
    """Download an object from a bucket.

    Args:
        bucket: The bucket name.
        key: The object key (path).
        auth_key: The bucket key or master key. Not needed for public buckets.
        encoding: "utf-8" (default) returns text, "base64" returns base64-encoded binary.
    """
    err = _check_bucket(bucket)
    if err:
        return err

    bc = _config.buckets[bucket]
    if not bc.public and not _check_key(bucket, auth_key):
        return {"error": f"Bucket '{bucket}' does not exist"}

    try:
        async with _locks.read(bucket, key):
            meta = get_object_meta(_db, bucket, key)
            if not meta:
                return {"error": f"Object '{key}' not found"}

            if meta["size"] > MCP_MAX_DOWNLOAD_BYTES:
                return {
                    "error": f"Object too large for MCP download ({meta['size']} bytes). "
                    f"Use the HTTP API instead: GET /{bucket}/{key}"
                }

            path = read_file(DATA_DIR, bucket, key)
            if not path:
                delete_object_meta(_db, bucket, key)
                return {"error": f"Object '{key}' not found"}

            try:
                data = path.read_bytes()
            except OSError:
                return {"error": "Storage error"}

            if encoding == "base64":
                body = base64.b64encode(data).decode("ascii")
            else:
                try:
                    body = data.decode("utf-8")
                except UnicodeDecodeError:
                    body = base64.b64encode(data).decode("ascii")
                    encoding = "base64"

            return {
                "ok": True,
                "content": body,
                "encoding": encoding,
                "content_type": meta["content_type"],
                "size": meta["size"],
                "etag": meta["etag"],
            }
    except (LockTimeout, LockHoldTimeout, LockOverloaded) as exc:
        return _lock_err(exc)


@mcp.tool(annotations=ToolAnnotations(destructiveHint=True))
async def delete_object(bucket: str, key: str, auth_key: str) -> dict[str, Any]:
    """Delete an object from a bucket.

    Args:
        bucket: The bucket name.
        key: The object key (path).
        auth_key: The bucket key or master key for authentication.
    """
    err = _check_bucket(bucket)
    if err:
        return err
    if not _check_key(bucket, auth_key):
        return {"error": f"Bucket '{bucket}' does not exist"}

    try:
        async with _locks.write(bucket, key):
            delete_file(DATA_DIR, bucket, key)
            delete_object_meta(_db, bucket, key)
            log.info("MCP DELETE", extra={"bucket": bucket, "key": key})
            return {"ok": True}
    except (LockTimeout, LockHoldTimeout, LockOverloaded) as exc:
        return _lock_err(exc)


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def list_objects(
    bucket: str,
    auth_key: str = "",
    prefix: str = "",
    max_keys: int = 100,
) -> dict[str, Any]:
    """List objects in a bucket.

    Args:
        bucket: The bucket name.
        auth_key: The bucket key or master key. Not needed for public buckets.
        prefix: Filter by key prefix (e.g. "images/" to list only images/).
        max_keys: Maximum number of objects to return (default 100, max 1000).
    """
    err = _check_bucket(bucket)
    if err:
        return err

    bc = _config.buckets[bucket]
    if not bc.public and not _check_key(bucket, auth_key):
        return {"error": f"Bucket '{bucket}' does not exist"}

    max_keys = max(1, min(max_keys, 1000))
    objects = list_objects_meta(_db, bucket, prefix, max_keys)

    return {
        "ok": True,
        "bucket": bucket,
        "count": len(objects),
        "objects": [
            {"key": o["key"], "size": o["size"], "content_type": o["content_type"]}
            for o in objects
        ],
    }


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def list_buckets(auth_key: str) -> dict[str, Any]:
    """List buckets accessible with the given key.

    Pass the master key to list all configured buckets.
    Pass a bucket key to list only that bucket.

    Args:
        auth_key: The master key (lists all buckets) or a bucket key (lists that bucket only).
    """
    import hmac as _hmac

    def _bc_dict(name: str, bc: Any) -> dict[str, Any]:
        return {
            "name": name,
            "public": bc.public,
            "ttl_seconds": bc.ttl_seconds,
            "max_file_size_bytes": bc.max_file_size_bytes,
        }

    if _config.master_key and _hmac.compare_digest(auth_key, _config.master_key):
        return {
            "ok": True,
            "buckets": [_bc_dict(n, bc) for n, bc in _config.buckets.items()],
        }

    for name, bc in _config.buckets.items():
        if _hmac.compare_digest(auth_key, bc.key):
            return {"ok": True, "buckets": [_bc_dict(name, bc)]}

    return {"error": "Access denied"}


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def object_info(bucket: str, key: str, auth_key: str = "") -> dict[str, Any]:
    """Get metadata about an object without downloading it.

    Args:
        bucket: The bucket name.
        key: The object key (path).
        auth_key: The bucket key or master key. Not needed for public buckets.
    """
    err = _check_bucket(bucket)
    if err:
        return err

    bc = _config.buckets[bucket]
    if not bc.public and not _check_key(bucket, auth_key):
        return {"error": f"Bucket '{bucket}' does not exist"}

    meta = get_object_meta(_db, bucket, key)
    if not meta:
        return {"error": f"Object '{key}' not found"}

    return {
        "ok": True,
        "key": meta["key"],
        "content_type": meta["content_type"],
        "size": meta["size"],
        "etag": meta["etag"],
        "uploaded_at": meta["uploaded_at"],
        "expires_at": meta.get("expires_at"),
    }


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def presign_url(
    bucket: str,
    key: str,
    auth_key: str,
    method: str = "GET",
    expires: int = 3600,
    base_url: str = "",
    host: str = "",
) -> dict[str, Any]:
    """Generate an S3-compatible presigned URL for an object.

    Returns a proper AWS Sig V4 presigned URL. The private key signs the URL
    but never appears in it. Anyone with the URL can perform the named method
    on the object until it expires.

    Args:
        bucket: The bucket name.
        key: The object key (path).
        auth_key: The bucket key or master key for authentication.
        method: HTTP verb the URL grants — "GET" (default) or "PUT".
        expires: Seconds until the URL expires (default 3600, max 604800 = 7 days).
        base_url: Base URL for the generated link (e.g. "http://host:8080").
        host: Hostname for the URL (derived from base_url if empty).
    """
    from sigv4 import generate_presigned_url
    from urllib.parse import urlparse

    err = _check_bucket(bucket)
    if err:
        return err
    if not _check_key(bucket, auth_key):
        return {"error": f"Bucket '{bucket}' does not exist"}

    method = method.upper()
    if method not in {"GET", "PUT"}:
        return {"error": "method must be GET or PUT"}

    bc = _config.buckets[bucket]

    # extract prefix from base_url path (e.g. http://host:4000/storage → prefix=/storage)
    parsed = urlparse(base_url)
    prefix = parsed.path.rstrip("/")
    base_no_path = f"{parsed.scheme}://{parsed.netloc}" if parsed.scheme else base_url

    # public buckets + GET: plain URL — reads are open so no signature needed.
    # PUT must always sign — public buckets allow anonymous reads, not writes.
    if bc.public and method == "GET":
        url = f"{base_no_path}{prefix}/{bucket}/{key}"
        log.info(
            "MCP presign",
            extra={"bucket": bucket, "key": key, "method": method, "public": True},
        )
        return {"ok": True, "url": url, "method": method, "expires": None}

    expires = max(1, min(expires, 604800))
    url = generate_presigned_url(
        base_url=base_no_path,
        bucket=bucket,
        key=key,
        public_key=bc.public_key,
        secret_key=bc.key,
        expires=expires,
        host=host,
        prefix=prefix,
        method=method,
    )

    log.info(
        "MCP presign",
        extra={"bucket": bucket, "key": key, "method": method, "expires": expires},
    )
    return {"ok": True, "url": url, "method": method, "expires": expires}
