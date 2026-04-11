import hmac
import sqlite3
import uuid

from fastapi import APIRouter, Request, Response
from fastapi.responses import FileResponse, JSONResponse

from auth import check_aws_auth, check_bearer, extract_bearer
from sigv4 import generate_presigned_url, parse_header, verify_header
from config import DATA_DIR, AppConfig, BucketConfig
from lock import LockHoldTimeout, LockManager, LockOverloaded, LockTimeout
from db import delete_object_meta, get_object_meta, list_objects_meta, upsert_object
from logger import get_logger, get_request_id
from mimetype import detect as detect_mimetype
from s3xml import error_xml, list_buckets_xml, list_objects_xml, location_xml
from storage import delete_file, finalize_file, read_file, write_path

log = get_logger(__name__)

router = APIRouter()

# wired up by main.py at startup
config: AppConfig = None  # type: ignore[assignment]
db_conn: sqlite3.Connection = None  # type: ignore[assignment]
lock_manager: LockManager = None  # type: ignore[assignment]

_GENERIC_CONTENT_TYPES = {"", "application/octet-stream", "application/x-www-form-urlencoded"}


def _is_s3(request: Request) -> bool:
    auth = request.headers.get("authorization", "")
    if auth.startswith("AWS4-HMAC-SHA256"):
        return True
    for h in request.headers:
        if h.lower().startswith("x-amz-"):
            return True
    return False


def _err(request: Request, status: int, code: str, message: str) -> Response:
    rid = get_request_id()
    log.warning("error response", extra={"status": status, "code": code, "detail": message})
    if _is_s3(request):
        return Response(
            content=error_xml(code, message, request_id=rid),
            status_code=status,
            media_type="application/xml",
        )
    return JSONResponse(
        {"error": code, "message": message, "request_id": rid},
        status_code=status,
    )


def _lock_err(request: Request, exc: Exception) -> Response:
    if isinstance(exc, LockOverloaded):
        return _err(request, 503, "ServiceUnavailable", "Too many concurrent requests for this object")
    return _err(request, 503, "RequestTimeout", "Lock timed out — try again")


def _check_any_auth(request: Request, bucket: str) -> bool:
    """Check bearer token OR AWS Sig V4 auth for this bucket."""
    token = extract_bearer(request)
    if check_bearer(config, bucket, token):
        return True
    return check_aws_auth(request, config, bucket)


def _identify_auth(request: Request) -> str | None:
    """Identify who authenticated: returns "master", a bucket name, or None."""
    token = extract_bearer(request)
    if token:
        if config.master_key and hmac.compare_digest(token, config.master_key):
            return "master"
        for name, bc in config.buckets.items():
            if hmac.compare_digest(token, bc.key):
                return name

    hdr_creds = parse_header(request)
    if hdr_creds:
        if hdr_creds.access_key == config.master_public_key and config.master_key:
            if verify_header(request, config.master_key):
                return "master"
        bc = config.find_by_public_key(hdr_creds.access_key)
        if bc and verify_header(request, bc.key):
            return bc.name

    return None


def _get_bucket(request: Request, bucket: str) -> tuple[BucketConfig, Response | None]:
    bc = config.buckets.get(bucket)
    if not bc:
        return BucketConfig("", False, "", "", 0, 0), _err(
            request,
            404,
            "NoSuchBucket",
            f"Bucket '{bucket}' does not exist",
        )
    return bc, None


def _check_write_auth(request: Request, bucket: str) -> Response | None:
    if _check_any_auth(request, bucket):
        return None
    # return 404 so unauthorized callers cannot confirm the bucket exists
    return _err(request, 404, "NoSuchBucket", f"Bucket '{bucket}' does not exist")


def _check_read_auth(request: Request, bc: BucketConfig) -> Response | None:
    # S3 presigned URL (X-Amz-Signature in query) — verify signature + expiry
    if "X-Amz-Signature" in request.query_params:
        if check_aws_auth(request, config, bc.name):
            return None
        return _err(request, 403, "AccessDenied", "Invalid or expired presigned URL")
    # public buckets: allow unauthenticated reads
    if bc.public:
        return None
    # private buckets: require header auth (bearer or AWS sig v4)
    if _check_any_auth(request, bc.name):
        return None
    # return 404 so unauthorized callers cannot confirm the bucket exists
    return _err(request, 404, "NoSuchBucket", f"Bucket '{bc.name}' does not exist")


# ── service root ─────────────────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@router.get("/")
async def list_buckets(request: Request) -> Response:
    scope = _identify_auth(request)
    if scope is None:
        return _err(request, 403, "AccessDenied", "Access denied")

    names = list(config.buckets.keys()) if scope == "master" else [scope]
    log.debug("list buckets", extra={"count": len(names), "scope": scope})
    if _is_s3(request):
        return Response(content=list_buckets_xml(names), media_type="application/xml")
    return JSONResponse({"buckets": names})


# ── presign ──────────────────────────────────────────────────────────────────


@router.post("/presign/{bucket}/{key:path}")
async def presign(request: Request, bucket: str, key: str) -> Response:
    """Generate an S3-compatible presigned URL for reading an object.

    Returns a proper AWS Sig V4 presigned URL. The private key signs the URL
    but never appears in it — only the public_key (access ID) is visible.

    Query params:
        expires: seconds until URL expires (default 3600, max 604800 = 7 days)
    """
    bc, err = _get_bucket(request, bucket)
    if err:
        return err
    auth_err = _check_write_auth(request, bucket)
    if auth_err:
        return auth_err

    base = str(request.base_url).rstrip("/")
    prefix = request.scope.get("_original_path", "")
    # extract prefix: original=/storage/presign/bucket/key → prefix=/storage
    # stripped path is /presign/bucket/key, so prefix = original minus stripped
    stripped = request.url.path  # /presign/bucket/key
    if prefix and prefix.endswith(stripped):
        prefix = prefix[: -len(stripped)]
    else:
        prefix = ""

    # public buckets: plain URL — no signature needed since GET is open
    if bc.public:
        url = f"{base}{prefix}/{bucket}/{key}"
        log.info("presign", extra={"bucket": bucket, "key": key, "public": True})
        return JSONResponse({"url": url, "expires": None})

    try:
        expires = int(request.query_params.get("expires", "3600"))
    except ValueError:
        return _err(request, 400, "InvalidArgument", "expires must be an integer")
    expires = max(1, min(expires, 604800))

    host = request.headers.get("host", request.url.netloc)
    url = generate_presigned_url(
        base_url=base,
        bucket=bucket,
        key=key,
        public_key=bc.public_key,
        secret_key=bc.key,
        expires=expires,
        host=host,
        prefix=prefix,
    )

    log.info("presign", extra={"bucket": bucket, "key": key, "expires": expires})
    return JSONResponse({"url": url, "expires": expires})


# ── bucket ops ───────────────────────────────────────────────────────────────


@router.head("/{bucket}")
async def head_bucket(request: Request, bucket: str) -> Response:
    bc, err = _get_bucket(request, bucket)
    if err:
        return err
    read_err = _check_read_auth(request, bc)
    if read_err:
        return read_err
    return Response(status_code=200)


@router.put("/{bucket}")
async def create_bucket(request: Request, bucket: str) -> Response:
    """S3 compat: noop if bucket exists in config, 404 if not."""
    _, err = _get_bucket(request, bucket)
    if err:
        return err
    auth_err = _check_write_auth(request, bucket)
    if auth_err:
        return auth_err
    return Response(status_code=200)


@router.get("/{bucket}")
async def list_objects_route(request: Request, bucket: str) -> Response:
    bc, err = _get_bucket(request, bucket)
    if err:
        return err

    # S3 GetBucketLocation
    if "location" in request.query_params:
        return Response(content=location_xml(), media_type="application/xml")

    read_err = _check_read_auth(request, bc)
    if read_err:
        return read_err

    prefix = request.query_params.get("prefix", "")
    try:
        max_keys = int(request.query_params.get("max-keys", "1000"))
    except ValueError:
        return _err(request, 400, "InvalidArgument", "max-keys must be an integer")
    max_keys = max(1, min(max_keys, 1000))

    objects = list_objects_meta(db_conn, bucket, prefix, max_keys)
    log.debug("list objects", extra={"bucket": bucket, "prefix": prefix, "count": len(objects)})

    if _is_s3(request):
        return Response(
            content=list_objects_xml(bucket, objects, prefix, max_keys),
            media_type="application/xml",
        )
    return JSONResponse({"bucket": bucket, "objects": objects})


# ── object ops ───────────────────────────────────────────────────────────────


@router.put("/{bucket}/{key:path}")
async def put_object(request: Request, bucket: str, key: str) -> Response:
    bc, err = _get_bucket(request, bucket)
    if err:
        return err
    auth_err = _check_write_auth(request, bucket)
    if auth_err:
        return auth_err

    try:
        dest = write_path(DATA_DIR, bucket, key)
    except ValueError:
        return _err(request, 400, "InvalidKey", "Invalid object key")

    try:
        async with lock_manager.write(bucket, key):
            return await _do_put(request, bc, bucket, key, dest)
    except (LockTimeout, LockHoldTimeout, LockOverloaded) as exc:
        return _lock_err(request, exc)


async def _do_put(request, bc, bucket, key, dest):
    max_bytes = bc.max_file_size_bytes
    tmp_path = dest.with_suffix(f".tmp.{uuid.uuid4().hex[:8]}")
    total = 0
    try:
        with open(tmp_path, "wb") as f:
            async for chunk in request.stream():
                total += len(chunk)
                if max_bytes > 0 and total > max_bytes:
                    tmp_path.unlink(missing_ok=True)
                    return _err(
                        request,
                        413,
                        "EntityTooLarge",
                        f"File exceeds maximum size of {max_bytes} bytes",
                    )
                f.write(chunk)
        tmp_path.rename(dest)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise

    size, etag = finalize_file(dest)

    client_ct = request.headers.get("content-type", "")
    if client_ct and client_ct not in _GENERIC_CONTENT_TYPES:
        content_type = client_ct
    else:
        head = dest.read_bytes()[:8192] if size > 0 else b""
        content_type = detect_mimetype(key, head)
    try:
        upsert_object(db_conn, bucket, key, content_type, size, etag, bc.ttl_seconds)
    except Exception:
        dest.unlink(missing_ok=True)
        raise

    log.info(
        "PUT",
        extra={"bucket": bucket, "key": key, "size": size, "content_type": content_type},
    )
    return Response(status_code=200, headers={"ETag": f'"{etag}"'})


@router.get("/{bucket}/{key:path}")
async def get_object(request: Request, bucket: str, key: str) -> Response:
    bc, err = _get_bucket(request, bucket)
    if err:
        return err
    read_err = _check_read_auth(request, bc)
    if read_err:
        return read_err

    try:
        async with lock_manager.read(bucket, key):
            meta = get_object_meta(db_conn, bucket, key)
            if not meta:
                return _err(request, 404, "NoSuchKey", f"Object '{key}' not found")

            path = read_file(DATA_DIR, bucket, key)
            if not path:
                delete_object_meta(db_conn, bucket, key)
                return _err(request, 404, "NoSuchKey", f"Object '{key}' not found")

            log.debug("GET", extra={"bucket": bucket, "key": key, "size": meta["size"]})
            return FileResponse(
                path=str(path),
                media_type=meta["content_type"],
                headers={
                    "ETag": f"\"{meta['etag']}\"",
                    "Last-Modified": meta["uploaded_at"],
                    "Content-Length": str(meta["size"]),
                },
            )
    except (LockTimeout, LockHoldTimeout, LockOverloaded) as exc:
        return _lock_err(request, exc)


@router.head("/{bucket}/{key:path}")
async def head_object(request: Request, bucket: str, key: str) -> Response:
    bc, err = _get_bucket(request, bucket)
    if err:
        return err
    read_err = _check_read_auth(request, bc)
    if read_err:
        return read_err

    try:
        async with lock_manager.read(bucket, key):
            meta = get_object_meta(db_conn, bucket, key)
            if not meta:
                return _err(request, 404, "NoSuchKey", f"Object '{key}' not found")

            return Response(
                status_code=200,
                headers={
                    "Content-Type": meta["content_type"],
                    "Content-Length": str(meta["size"]),
                    "ETag": f"\"{meta['etag']}\"",
                    "Last-Modified": meta["uploaded_at"],
                },
            )
    except (LockTimeout, LockHoldTimeout, LockOverloaded) as exc:
        return _lock_err(request, exc)


@router.delete("/{bucket}/{key:path}")
async def delete_object_route(request: Request, bucket: str, key: str) -> Response:
    _, err = _get_bucket(request, bucket)
    if err:
        return err
    auth_err = _check_write_auth(request, bucket)
    if auth_err:
        return auth_err

    try:
        async with lock_manager.write(bucket, key):
            delete_file(DATA_DIR, bucket, key)
            delete_object_meta(db_conn, bucket, key)
            log.info("DELETE", extra={"bucket": bucket, "key": key})
            # S3 returns 204 even if object didn't exist
            return Response(status_code=204)
    except (LockTimeout, LockHoldTimeout, LockOverloaded) as exc:
        return _lock_err(request, exc)
