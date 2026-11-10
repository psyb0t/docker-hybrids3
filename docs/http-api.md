---
title: "HTTP API"
description: "Every hybrids3 HTTP route with its auth, query parameters, response headers, status codes, JSON and XML error formats and error codes."
nav_order: 5
---

# HTTP API

The plain HTTP API is for `curl`, shell scripts and any client that would rather send a Bearer token than sign requests. It is the same set of routes the [S3 API](s3-api.md) uses; only the authentication and the response format differ. The routes live in [`app/routes.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/routes.py).

All paths below are relative to the server root, or to `path_prefix` when one is [configured](configuration.md#top-level-settings).

## Authentication

Send the bucket's private `key`, or the master key, as a Bearer token:

```text
Authorization: Bearer <key>
```

Reads on a public bucket need no header. Everything else does: writes, deletes, presigning, reads on a private bucket and listing buckets. [Keys and access](keys-and-access.md) has the full table.

```bash
# write to a bucket
curl -X PUT http://localhost:8080/uploads/file.txt \
  -H "Authorization: Bearer uploads-secret" \
  --data-binary "hello"

# read from a public bucket, no key needed
curl http://localhost:8080/uploads/file.txt

# read from a private bucket
curl http://localhost:8080/permanent/doc.pdf \
  -H "Authorization: Bearer perm-secret"
```

## Routes

| Method | Path | Auth | What it does |
| --- | --- | --- | --- |
| `GET` | `/health` | none | Returns `{"status":"ok"}` |
| `GET` | `/` | master or bucket key | Lists buckets. The master key sees all of them, a bucket key sees only its own |
| `HEAD` | `/{bucket}` | read | `200` if the bucket exists and the caller may read it, otherwise `404` |
| `PUT` | `/{bucket}` | write | Does nothing. `200` if the bucket exists, `404` if not. It exists because boto3 may call `create_bucket` |
| `GET` | `/{bucket}` | read | Lists objects |
| `GET` | `/{bucket}?location` | none | S3 `GetBucketLocation`. Returns an empty `LocationConstraint` XML document |
| `PUT` | `/{bucket}/{key}` | write | Uploads an object, replacing any object with the same key |
| `GET` | `/{bucket}/{key}` | read | Downloads an object |
| `HEAD` | `/{bucket}/{key}` | read | Object metadata without the body |
| `DELETE` | `/{bucket}/{key}` | write | Deletes an object. `204` even if it did not exist |
| `POST` | `/presign/{bucket}/{key}` | write | Creates a presigned URL. See [Presigned URLs](presigned-urls.md) |
| `POST` | `/mcp/` | per tool | MCP Streamable HTTP endpoint. See [MCP server](mcp.md) |

"Read" means no key on a public bucket and the bucket key, master key or a presigned GET URL on a private one. "Write" means the bucket key, the master key or, for `PUT /{bucket}/{key}`, a presigned PUT URL.

Any other method on these paths gets `405` with `{"detail":"Method Not Allowed"}`.

## Uploading

```bash
curl -X PUT http://localhost:8080/uploads/reports/2024/january.pdf \
  -H "Authorization: Bearer uploads-secret" \
  --data-binary @january.pdf
```

- The body is streamed to disk, not held in memory. When the bucket has a `max_file_size` and the body grows past it, the upload stops with `413 EntityTooLarge` and nothing is stored.
- Keys can contain `/`. hybrids3 creates the parent directories on write and removes them again when they become empty after a delete.
- A key that resolves outside the bucket directory, such as one with `../` segments, gets `400 InvalidKey`.
- The response is `200` with an empty body and an `ETag` header holding the MD5 of the content in quotes.
- Uploading to an existing key replaces the object and resets its [TTL](storage.md#ttl-expiry).
- The content type comes from the `Content-Type` header, unless the header is missing, `application/octet-stream` or `application/x-www-form-urlencoded` (what `curl -d` and `--data-binary` send). Then hybrids3 [detects it](storage.md#mime-type-detection).

## Downloading and HEAD

`GET /{bucket}/{key}` returns the bytes. `GET` and `HEAD` both send:

| Header | Value |
| --- | --- |
| `Content-Type` | The stored content type |
| `Content-Length` | Size in bytes |
| `ETag` | MD5 of the content, in double quotes |
| `Last-Modified` | Time of the last write as an ISO 8601 UTC timestamp, such as `2026-11-10T07:18:56.200941+00:00`. This is not the RFC 7231 date format HTTP clients usually expect |

A missing object gets `404 NoSuchKey`.

## Listing objects

```bash
curl "http://localhost:8080/uploads?prefix=images/&max-keys=50" \
  -H "Authorization: Bearer uploads-secret"
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `prefix` | none | Only keys that start with this text. `%` and `_` match themselves, not as wildcards |
| `max-keys` | `1000` | Most objects to return, clamped to 1 to 1000. A non-integer gets `400 InvalidArgument` |

Objects come back sorted by key. There is no pagination: with more than 1000 matching objects, narrow the `prefix`. The JSON response:

```json
{
  "bucket": "uploads",
  "objects": [
    {
      "bucket": "uploads",
      "key": "images/cat.jpg",
      "content_type": "image/jpeg",
      "size": 48231,
      "etag": "49f68a5c8493ec2c0bf489821c21fc3b",
      "uploaded_at": "2026-11-10T07:18:56.200941+00:00",
      "expires_at": "2026-11-11T07:18:56.200941+00:00"
    }
  ]
}
```

`expires_at` is `null` in buckets without a TTL.

## Listing buckets

```bash
# the master key sees every bucket
curl http://localhost:8080/ \
  -H "Authorization: Bearer your-master-key"

# a bucket key sees only its own bucket
curl http://localhost:8080/ \
  -H "Authorization: Bearer uploads-secret"
```

The response is `{"buckets":["uploads","permanent"]}`. Without a valid key the answer is `403 AccessDenied`.

## Response format

A request that carries an `Authorization: AWS4-HMAC-SHA256 ...` header or any `x-amz-*` header is treated as an S3 request and gets XML. Everything else gets JSON.

JSON errors look like this:

```json
{
  "error": "NoSuchKey",
  "message": "Object 'zz' not found",
  "request_id": "393dba50439f"
}
```

S3 errors use the S3 `<Error>` document with `Code`, `Message` and `RequestId`.

Every response carries `X-Request-Id`, which matches the `rid` field in the [logs](troubleshooting.md#log-format), and `X-Content-Type-Options: nosniff`.

## Error codes

| Status | Code | When |
| --- | --- | --- |
| `400` | `InvalidArgument` | `max-keys` or `expires` is not an integer, or `method` is not `GET` or `PUT` |
| `400` | `InvalidKey` | The key resolves outside the bucket directory |
| `403` | `AccessDenied` | `GET /` without a valid key, or a presigned GET URL that is invalid or expired |
| `404` | `NoSuchBucket` | The bucket does not exist, the caller may not see it, or a presigned PUT URL is invalid or expired |
| `404` | `NoSuchKey` | The object does not exist |
| `413` | `EntityTooLarge` | The upload is larger than the bucket's `max_file_size` |
| `503` | `ServiceUnavailable` | Too many requests are already waiting for this object (`lock_max_waiters`) |
| `503` | `RequestTimeout` | The request waited longer than `lock_acquire_timeout` or held the lock longer than `lock_hold_timeout` |

[Storage, expiry and locking](storage.md#locking) explains the `503` cases.

## Reserved paths

FastAPI serves its generated API pages at `/docs`, `/redoc` and `/openapi.json`, without a key. They are matched before the bucket routes, so a bucket named `docs`, `redoc` or `openapi.json` cannot be listed with `GET /{bucket}`. Object routes under those names still work. Pick other bucket names.
