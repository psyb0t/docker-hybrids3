# HybridS3

Lightweight object storage that speaks S3 (boto3/AWS SDK compatible), plain HTTP, and MCP. SQLite for metadata, flat files on disk.

---

## Table of Contents

- [Why](#why)
- [Quick Start](#quick-start)
- [Running](#running)
- [Configuration](#configuration)
- [Keys and Access](#keys-and-access)
  - [Key pair model](#key-pair-model)
  - [Master key](#master-key)
  - [Bucket visibility](#bucket-visibility)
- [HTTP API](#http-api)
  - [Authentication](#authentication)
  - [Endpoints](#endpoints)
  - [Object keys](#object-keys)
  - [Response format](#response-format)
- [S3 Interface](#s3-interface)
  - [Authentication](#authentication-1)
  - [Operations](#operations)
- [MCP Interface](#mcp-interface)
  - [Connecting](#connecting)
  - [Authentication](#authentication-2)
  - [Tools](#tools)
- [Presigned URLs](#presigned-urls)
- [MIME Type Detection](#mime-type-detection)
- [TTL and Expiry](#ttl-and-expiry)
- [Locking](#locking)
- [Logging](#logging)
- [Behind a Reverse Proxy](#behind-a-reverse-proxy)
- [Security](#security)
- [Testing](#testing)
- [Architecture](#architecture)
- [Limitations](#limitations)
- [License](#license)

---

## Why

**Most self-hosted S3-compatible storage is designed for large-scale deployments.** Distributed erasure coding, IAM policies, WORM compliance, full web consoles — useful if you're running a cloud, overkill if you just want a place to put files that various services and AI agents can read and write.

**AWS Sig V4 breaks behind reverse proxy path prefixes.** Most implementations verify signatures using the full original upstream path. Put them behind nginx at `/storage/`, nginx strips the prefix, the server sees `/bucket/key` instead of `/storage/bucket/key`, the signature check fails. HybridS3 has a `path_prefix` config option — set it to `/storage` and all routes move under that prefix. No path stripping, no special proxy headers. boto3's signed path matches what the server sees.

**Three interfaces, one service.** boto3 works out of the box. Plain HTTP with `curl` works. AI agents connect via MCP and get structured tool definitions. No separate services for different clients.

**Buckets are configuration, not state.** There is no API to create or delete buckets. They live in the YAML config file. You always know exactly what exists, it's version-controlled, and there are no surprise buckets accumulating garbage.

**TTL expiry is built in.** Set `ttl: 24h` on a bucket and objects expire automatically after their last write. No lifecycle policies, no cron jobs, no separate process.

**Readable and modifiable.** Small enough to understand in an afternoon.

---

## Quick Start

```bash
# get the example config
wget -O config.yaml https://raw.githubusercontent.com/psyb0t/docker-hybrids3/master/config.example.yaml

# edit it — set your keys and define your buckets
vi config.yaml

# run
docker run -d --name hybrids3 \
    -p 8080:8080 \
    -v ./config.yaml:/config/config.yaml:ro \
    -v hybrids3-data:/data \
    psyb0t/hybrids3

# verify
curl http://localhost:8080/health
```

---

## Running

The container expects:

- Config file at `/config/config.yaml`
- Data directory at `/data`
- Port `8080`

Runs as UID 1000.

**docker run:**

```bash
docker run -d --name hybrids3 \
    -p 8080:8080 \
    -v ./config.yaml:/config/config.yaml:ro \
    -v hybrids3-data:/data \
    psyb0t/hybrids3
```

**docker-compose:**

```yaml
services:
  hybrids3:
    image: psyb0t/hybrids3
    ports:
      - "8080:8080"
    volumes:
      - ./config.yaml:/config/config.yaml:ro
      - hybrids3-data:/data
    restart: unless-stopped

volumes:
  hybrids3-data:
```

---

## Configuration

```yaml
# Cross-bucket god key. Works on every bucket for every operation.
# Only credential that can list all buckets. Keep secret.
master_key: "change-me-to-something-secret"

# Non-secret identifier paired with master_key in S3 auth (aws_access_key_id).
# Safe to share — it grants nothing without the master_key.
master_public_key: "master"

# How often the background loop runs to delete expired objects and orphan files.
# Accepts human-readable durations: 30s, 5m, 1h, or raw seconds: 60
cleanup_interval: 1m

# How long a request may wait to acquire a lock on an object before giving up with 503.
# Accepts seconds as a float. Applies per object key, globally across all buckets.
lock_acquire_timeout: 30

# How long a request may hold a lock before it is forcibly released and the request gets 503.
# Protects against slow or stalled uploads blocking writes on the same key indefinitely.
lock_hold_timeout: 300

# Maximum number of requests that may queue for the same object key at once.
# Once the queue is full, new requests are rejected immediately with 503.
lock_max_waiters: 100

# Serve all routes under this path prefix.
# Set this when running behind a reverse proxy at a subpath (e.g. /storage).
# Accepts "/storage" or "/storage/" — both are normalized.
# Leave empty or omit to serve at the root.
# path_prefix: /storage

# TTL formats:   30s  5m  1h  1h30m12s  1d  2d12h  0 (never expire)
# Size formats:  500B  50KB  10MB  1GB  0 (no limit)

buckets:
  uploads:
    # true  — anyone can read (GET/HEAD/LIST) without authentication
    # false — authentication required for all operations
    public: true

    # Private key for this bucket.
    # Used as the Bearer token value and as aws_secret_access_key in S3 auth.
    # Never transmitted — only used to sign or verify request signatures.
    # Keep secret.
    key: "uploads-secret"

    # Public identifier for this bucket in S3 auth (aws_access_key_id).
    # Also appears in presigned URL Credential= fields.
    # Safe to share — it identifies the bucket but grants no access.
    # Defaults to the bucket name if not set.
    public_key: "uploads-id"

    # Objects expire this long after their last write. Overwriting resets the clock.
    # 0 means objects never expire.
    ttl: 24h

    # Maximum upload size. Requests over this limit are rejected with 413.
    # 0 means no limit.
    max_file_size: 50MB

  permanent:
    public: false
    key: "perm-secret"
    public_key: "permanent-id"
    ttl: 0
    max_file_size: 100MB
```

---

## Keys and Access

### Key pair model

Each bucket has two keys defined in config:

| Config field | Role                                                                                                                                               | Keep secret?       |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| `key`        | The private key. Used to authenticate Bearer requests and to sign S3 signatures. Never transmitted — only used locally to compute or verify HMACs. | Yes                |
| `public_key` | The public identifier. Used as `aws_access_key_id` in S3 auth and appears in presigned URL `Credential=` fields. Grants nothing on its own.        | No — safe to share |

The split is what makes presigned URLs work safely. A presigned URL must embed an identifier in the `Credential=` field so the server knows which key to verify against — that identifier is the `public_key`. Since it is non-secret, having it in the URL is fine. The private key signs the URL on the server and never appears in it.

### Master key

The `master_key` is a cross-bucket credential that works on every bucket for every operation, without needing individual bucket keys. Two situations call for it:

- You need to operate across multiple buckets from a single client
- You need to list all configured buckets — bucket keys only see their own bucket in `list_buckets`

The `master_public_key` is the non-secret identifier that pairs with `master_key` in S3 auth (used as `aws_access_key_id`).

Do not embed the master key in client-facing code. Use per-bucket keys for that — they limit access to exactly one bucket.

### Bucket visibility

| Setting         | GET / HEAD / LIST                              | PUT / DELETE / presign   |
| --------------- | ---------------------------------------------- | ------------------------ |
| `public: true`  | no authentication required                     | bucket key or master key |
| `public: false` | bucket key, master key, or valid presigned URL | bucket key or master key |

---

## HTTP API

### Authentication

HTTP requests authenticate using a Bearer token in the `Authorization` header. Pass the bucket's private `key`, or the master key for cross-bucket operations.

```
Authorization: Bearer <private_key>
```

- **Public bucket reads** (GET, HEAD, LIST) — no authentication required.
- **All writes** (PUT, DELETE) and **reads on private buckets** — require the bucket key or master key.
- **Listing buckets** (`GET /`) — master key lists all buckets; bucket key lists only its own bucket.
- **Presign endpoint** (`POST /presign/...`) — requires the bucket key or master key.

```bash
# write to a bucket
curl -X PUT http://localhost:8080/uploads/file.txt \
  -H "Authorization: Bearer uploads-secret" \
  -d "hello"

# read from a public bucket — no auth needed
curl http://localhost:8080/uploads/file.txt

# read from a private bucket
curl http://localhost:8080/permanent/doc.pdf \
  -H "Authorization: Bearer perm-secret"

# list all buckets — master key sees all
curl http://localhost:8080/ \
  -H "Authorization: Bearer your-master-key"

# list buckets — bucket key sees only its own bucket
curl http://localhost:8080/ \
  -H "Authorization: Bearer uploads-secret"
```

---

### Endpoints

| Method   | Path                      | Auth                 | Description                                                        |
| -------- | ------------------------- | -------------------- | ------------------------------------------------------------------ |
| `GET`    | `/health`                 | none                 | Returns `{"status":"ok"}`                                          |
| `GET`    | `/`                       | master or bucket key | List buckets — master key lists all, bucket key lists only its own |
| `HEAD`   | `/{bucket}`               | read                 | Check if bucket exists — 200 or 404                                |
| `PUT`    | `/{bucket}`               | write                | S3 compatibility no-op: 200 if bucket exists in config, 404 if not |
| `GET`    | `/{bucket}`               | read                 | List objects in bucket                                             |
| `PUT`    | `/{bucket}/{key}`         | write                | Upload object                                                      |
| `GET`    | `/{bucket}/{key}`         | read                 | Download object                                                    |
| `HEAD`   | `/{bucket}/{key}`         | read                 | Object metadata — no body                                          |
| `DELETE` | `/{bucket}/{key}`         | write                | Delete object — returns 204 even if it does not exist              |
| `POST`   | `/presign/{bucket}/{key}` | write                | Generate a presigned URL                                           |
| `POST`   | `/mcp/`                   | per-tool             | MCP Streamable HTTP endpoint                                       |

`PUT /{bucket}` exists purely for S3 client compatibility. boto3 sends a `create_bucket` call before any operation, which maps to this endpoint. HybridS3 treats it as a no-op — no buckets are created or modified.

**Listing objects** accepts `prefix` and `max-keys` query parameters:

```bash
curl "http://localhost:8080/uploads?prefix=images/&max-keys=50" \
  -H "Authorization: Bearer uploads-secret"
```

**Upload** returns an `ETag` header (MD5 of the file content). GET and HEAD also return `ETag`, `Last-Modified`, and `Content-Length`.

---

### Object keys

Keys support nested paths using `/`. Parent directories are created automatically on write and pruned when empty on delete.

```bash
curl -X PUT http://localhost:8080/uploads/reports/2024/january.pdf \
  -H "Authorization: Bearer uploads-secret" \
  --data-binary @january.pdf
```

---

### Response format

Requests that include an AWS Sig V4 `Authorization` header receive S3-compatible XML responses. All other requests receive JSON. Error responses include an `"error"` field and a `"request_id"` field.

Every response includes `X-Request-Id` for log correlation and `X-Content-Type-Options: nosniff`.

---

## S3 Interface

### Authentication

S3 clients authenticate using AWS Signature V4. The client signs each request using the bucket's `public_key` as `aws_access_key_id` and the bucket's private `key` as `aws_secret_access_key`. The resulting `Authorization` header contains the access key ID in plaintext in the `Credential=` field, and the computed HMAC in `Signature=`. The private key is never transmitted — it is only used locally to compute the signature.

```
Authorization: AWS4-HMAC-SHA256 Credential=uploads-id/20240101/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=<hmac>
```

HybridS3 reads the access key ID from `Credential=`, finds the bucket with that `public_key`, then re-derives the expected signature using that bucket's private key and compares it to the one in the header. The access key ID alone grants nothing — the signature must match.

```python
import boto3
from botocore.config import Config

# per-bucket client — access is limited to the "uploads" bucket
s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:8080",
    aws_access_key_id="uploads-id",         # public_key from config
    aws_secret_access_key="uploads-secret",  # key from config
    region_name="us-east-1",
    config=Config(signature_version="s3v4"),
)

# master key client — access to all buckets, can list them
s3_admin = boto3.client(
    "s3",
    endpoint_url="http://localhost:8080",
    aws_access_key_id="master",              # master_public_key from config
    aws_secret_access_key="your-master-key", # master_key from config
    region_name="us-east-1",
    config=Config(signature_version="s3v4"),
)
```

---

### Operations

```python
s3.put_object(Bucket="uploads", Key="file.txt", Body=b"hello")
s3.get_object(Bucket="uploads", Key="file.txt")
s3.head_object(Bucket="uploads", Key="file.txt")
s3.delete_object(Bucket="uploads", Key="file.txt")
s3.list_objects_v2(Bucket="uploads", Prefix="images/")
s3_admin.list_buckets()  # master key: returns all buckets
s3.list_buckets()        # bucket key: returns only the "uploads" bucket

# generate a presigned URL for a private bucket object
url = s3.generate_presigned_url(
    "get_object",
    Params={"Bucket": "permanent", "Key": "doc.pdf"},
    ExpiresIn=3600,
)
```

---

## MCP Interface

An [MCP](https://modelcontextprotocol.io/) server runs at `/mcp/` using the Streamable HTTP transport. AI agents connect via any MCP-compatible client and receive structured tool definitions with typed inputs and outputs.

### Connecting

```json
{
  "mcpServers": {
    "hybrids3": {
      "type": "streamable-http",
      "url": "http://localhost:8080/mcp/"
    }
  }
}
```

### Authentication

#### Endpoint-level auth

The `/mcp/` endpoint accepts an optional token to authenticate the connection before any tool is invoked. Use the master key for full access, or a bucket key to limit the connection to that bucket's scope. The token is validated against the master key and all bucket keys.

Two methods are accepted:

**Authorization header** — for clients that support custom headers (e.g. Claude Code):

```
Authorization: Bearer <master_key_or_bucket_key>
```

**Query parameter** — for clients that cannot set custom headers (e.g. ChatGPT):

```
http://localhost:8080/mcp/?auth=<master_key_or_bucket_key>
```

If a token is provided and does not match any known key, the request is rejected with `401`. If no token is provided at all, the request passes through and per-tool auth applies.

#### Per-tool auth

Each tool that operates on a bucket accepts an `auth_key` parameter — the bucket's private `key` or the master key. This is checked independently of endpoint-level auth and controls what each individual tool call is allowed to do.

```
# public bucket read — no auth_key
download_object(bucket="uploads", key="file.txt")

# public bucket write — auth_key required
upload_object(bucket="uploads", key="file.txt", content="hello", auth_key="uploads-secret")

# private bucket — auth_key required for all operations
download_object(bucket="permanent", key="doc.pdf", auth_key="perm-secret")
upload_object(bucket="permanent", key="doc.pdf", content="...", auth_key="perm-secret")

# master key lists all buckets; bucket key lists only that bucket
list_buckets(auth_key="your-master-key")
list_buckets(auth_key="uploads-secret")  # returns only the uploads bucket
```

### Tools

| Tool              | Auth required                                   | Description                                                                                                                                  |
| ----------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `upload_object`   | bucket key or master key                        | Upload text or base64-encoded binary. Content type auto-detected if not specified.                                                           |
| `download_object` | bucket key or master key (private buckets only) | Download object content. Returns text or base64-encoded binary. Objects over 50 MB cannot be downloaded via MCP — use the HTTP API directly. |
| `delete_object`   | bucket key or master key                        | Delete an object.                                                                                                                            |
| `list_objects`    | bucket key or master key (private buckets only) | List objects with optional prefix filter. Default 100 results, max 1000.                                                                     |
| `list_buckets`    | master key or bucket key                        | Master key lists all buckets. Bucket key lists only that bucket.                                                                             |
| `object_info`     | bucket key or master key (private buckets only) | Get object metadata (size, content type, ETag, expiry time) without downloading the content.                                                 |
| `presign_url`     | bucket key or master key                        | Generate a shareable URL. Returns a plain URL for public buckets, a signed expiring URL for private buckets.                                 |

All tools return structured output (`structuredContent`) for clients that support it, with a plain text fallback.

---

## Presigned URLs

Presigned URLs allow anyone with the link to download an object for a limited time, without authentication credentials.

**Private bucket** — generates an AWS Sig V4 presigned URL. The server signs the URL using the bucket's private key, which never appears in the URL. The URL contains the `public_key` in the `Credential=` field and the HMAC in `X-Amz-Signature`. Expired or tampered URLs return 403.

```bash
# generate via HTTP endpoint
curl -X POST "http://localhost:8080/presign/permanent/doc.pdf?expires=3600" \
  -H "Authorization: Bearer perm-secret"

# response
{"url": "http://localhost:8080/permanent/doc.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&...&X-Amz-Signature=...", "expires": 3600}
```

Expiry range: 1 second to 604800 seconds (7 days). Default: 3600.

**Public bucket** — returns a plain URL with no signature and no expiry, since GET on public buckets requires no auth anyway.

```bash
curl -X POST "http://localhost:8080/presign/uploads/photo.jpg" \
  -H "Authorization: Bearer uploads-secret"

# response
{"url": "http://localhost:8080/uploads/photo.jpg", "expires": null}
```

Generating a presigned URL requires the bucket's private key or the master key. The resulting URL grants read-only access to that one object.

Both the `/presign/` HTTP endpoint and the `presign_url` MCP tool follow this same logic.

---

## MIME Type Detection

Content type is detected automatically on every upload. No `Content-Type` header is required. Detection uses [libmagic](https://man7.org/linux/man-pages/man3/libmagic.3.html) to inspect the first 8 KB of the file content, with a filename extension fallback when libmagic returns a generic type. The detected type is stored in metadata and returned in `Content-Type` on GET and HEAD responses.

To override auto-detection, set `Content-Type` explicitly on the upload request.

---

## TTL and Expiry

Set `ttl` on a bucket and objects expire automatically after that duration from the last write. Overwriting an object resets its expiry clock. Setting `ttl: 0` means objects never expire.

```yaml
buckets:
  staging:
    ttl: 1h # objects expire 1 hour after last write
```

A background cleanup loop runs every `cleanup_interval` seconds and performs two tasks:

1. **TTL expiry** — finds all objects whose `expires_at` has passed and deletes them from disk and metadata.
2. **Orphan cleanup** — scans each bucket's directory on disk and deletes files that have no corresponding metadata record. This handles files left behind by interrupted uploads.

Empty parent directories are removed up to the bucket root on every deletion.

---

## Locking

Every object key gets its own async read-write lock. Multiple readers hold the lock simultaneously. A writer gets exclusive access and blocks all concurrent readers and writers on that key. Locks are acquired before any operation begins and released after the response is fully sent.

This prevents torn reads, partial write visibility, and data corruption under concurrent access.

Three conditions cause `503 Service Unavailable`:

| Condition       | Trigger                                                                  |
| --------------- | ------------------------------------------------------------------------ |
| Overloaded      | More than `lock_max_waiters` requests queued for the same key            |
| Acquire timeout | A request waited `lock_acquire_timeout` seconds without getting the lock |
| Hold timeout    | A request held the lock longer than `lock_hold_timeout` seconds          |

The hold timeout protects against a slow or stalled upload holding a write lock indefinitely. When it fires, the lock is released and the request receives 503.

The defaults (30s acquire, 300s hold, 100 max waiters) suit large file uploads. For high-throughput small-object workloads, tighten these to shed load faster.

---

## Logging

Structured JSON logs to stdout, one entry per line:

```json
{
  "ts": "21:05:33",
  "level": "INFO",
  "src": "routes:put_object:227",
  "rid": "4432cd8a4ac1",
  "msg": "PUT",
  "bucket": "uploads",
  "key": "photo.jpg",
  "size": 48231,
  "content_type": "image/jpeg"
}
```

| Field   | Description                                                     |
| ------- | --------------------------------------------------------------- |
| `ts`    | Timestamp (HH:MM:SS)                                            |
| `level` | `INFO`, `WARNING`, or `ERROR`                                   |
| `src`   | `module:function:line`                                          |
| `rid`   | Request ID — matches the `X-Request-Id` response header         |
| `msg`   | Event name                                                      |
| others  | Context-specific: `bucket`, `key`, `size`, `content_type`, etc. |

The request ID appears in every log line produced during a request, making it easy to trace a single request end-to-end. Exceptions are logged with full tracebacks.

---

## Behind a Reverse Proxy

Set `path_prefix` in config to match the proxy location. HybridS3 serves all routes under that prefix natively — nginx forwards the path as-is, no stripping required. SigV4 signatures work because the client's signed path matches what the server sees.

```yaml
# config.yaml
path_prefix: /storage
```

```nginx
# nginx — just forward, no trailing-slash trick, no special headers
location /storage {
    proxy_pass http://hybrids3:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

With this config: boto3 at `http://yourdomain/storage`, curl at `http://yourdomain/storage/bucket/key`, MCP at `http://yourdomain/storage/mcp/`.

---

## Security

- **AWS Sig V4 verification** — full signature verification for header auth and presigned URLs; expired or tampered presigned URLs return 403
- **Constant-time key comparison** — all credential checks use `hmac.compare_digest` to prevent timing attacks
- **Private key isolation** — the private `key` is never returned in any response, never embedded in presigned URLs, and never logged
- **Path traversal protection** — all object key paths are validated with `Path.relative_to` before any disk access; upload attempts with traversal keys return 400
- **Bucket enumeration prevention** — `GET /` requires a valid key; master key lists all buckets, bucket key lists only its own; unauthorized or non-existent bucket access always returns 404 — callers cannot distinguish "does not exist" from "you don't have access"
- **SQLite prefix injection prevention** — user-supplied `prefix` values are escaped before use in `LIKE` queries
- **Atomic writes** — objects are written to a temporary file and renamed into place; readers never see partial writes
- **Streaming uploads** — request bodies are streamed directly to disk without buffering the full body in memory
- **Orphan file cleanup** — files on disk with no metadata record are deleted by the background sweep
- **Per-key RW locking** — overloaded or timed-out requests get 503 rather than queuing indefinitely
- **MCP error masking** — internal error details are not exposed to MCP tool callers
- **MCP download cap** — objects over 50 MB cannot be downloaded via MCP; use the HTTP API directly
- **Non-root container** — runs as UID 1000
- **`X-Content-Type-Options: nosniff`** — on every response

---

## Testing

```bash
# run unit tests + build image + run integration tests
make test

# run a single test by name
./test.sh test_s3_presigned_private

# list all available test names
./test.sh --help

# lock unit tests — no Docker required, runs in ~1 second
python -m pytest tests/test_lock_unit.py -v
```

All test output is teed to `test.log` automatically.

The integration tests cover: HTTP API, S3/boto3 compatibility, MCP tools, Bearer auth, AWS Sig V4 auth, presigned URLs (HTTP endpoint and S3 SDK), master key, cross-bucket key isolation, TTL expiry, orphan cleanup, MIME detection, size limits, path traversal attempts, binary files, concurrent reads and writes, RW lock behavior at unit and HTTP level, request IDs, and security headers.

---

## Architecture

```
app/
  main.py          FastAPI app, lifespan management, request ID middleware, MCP mount
  config.py        YAML config loader — TTL durations, sizes, key pairs, lock settings
  routes.py        HTTP and S3 endpoint handlers, presign endpoint
  lock.py          Per-key async read-write lock with acquire/hold timeouts and overload cap
  mcp_server.py    MCP tool definitions — Streamable HTTP at /mcp/
  auth.py          Bearer token and AWS Sig V4 authentication (header and presigned)
  sigv4.py         AWS Signature V4 signing and verification
  db.py            SQLite metadata store — WAL mode, objects table with TTL tracking
  storage.py       File I/O, path validation, atomic writes, orphan detection
  mimetype.py      Content type detection — libmagic content sniff with extension fallback
  s3xml.py         S3 XML response builders for list, error, and location responses
  logger.py        JSON structured logging with per-request ID propagation via contextvars
  scheduler.py     Background loop for TTL expiry and orphan file cleanup
```

---

## Limitations

- No multipart upload (S3's chunked upload protocol)
- No object versioning
- No ACLs beyond bucket-level public/private
- No bucket creation or deletion via API — buckets are defined in config
- No CORS headers — add these at the reverse proxy layer if needed
- No replication
- No encryption at rest

---

## License

[WTFPL](LICENSE)
