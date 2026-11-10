---
title: "Troubleshooting"
description: "Read hybrids3 JSON logs, fix each startup error, and track down 404s, 503s, signature mismatches, wrong content types and failed SDK calls."
nav_order: 13
---

# Troubleshooting

Start with `docker logs hybrids3`. Every request has an ID, returned in the `X-Request-Id` response header, and the same ID appears as `rid` on every log line the request produced.

## Log format

hybrids3 writes one JSON object per line to stdout, from [`app/logger.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/logger.py):

```json
{
  "ts": "21:05:33",
  "level": "INFO",
  "src": "routes:_do_put:340",
  "rid": "4432cd8a4ac1",
  "msg": "PUT",
  "bucket": "uploads",
  "key": "photo.jpg",
  "size": 48231,
  "content_type": "image/jpeg"
}
```

| Field | Meaning |
| --- | --- |
| `ts` | Time of day, `HH:MM:SS`, in the container's time zone (UTC unless you set one). No date |
| `level` | `INFO`, `WARNING` or `ERROR` |
| `src` | `module:function:line` that logged it |
| `rid` | Request ID, matching the `X-Request-Id` header. Missing on lines outside a request, such as startup and cleanup |
| `msg` | What happened, such as `PUT`, `DELETE`, `MCP PUT`, `presign`, `expired`, `orphan deleted` or `error response` |
| `error` | Exception message, on lines that log one. There is no traceback |
| others | Context: `bucket`, `key`, `size`, `content_type`, `status`, `code`, `detail`, `count` and so on |

Reads are logged at debug level, which is not enabled, so successful GETs and listings leave no hybrids3 line. Every error response does, as `msg: "error response"` at `WARNING` with `status`, `code` and `detail`.

uvicorn, the HTTP server, adds its own plain-text lines: startup messages and one access log line per request, such as `INFO: 172.17.0.1:51234 - "GET /health HTTP/1.1" 200 OK`. Filter on lines starting with `{` to keep only the JSON.

At startup a healthy server logs `MCP server mounted`, `HybridS3 started` with the bucket count, and one `bucket configured` line per bucket with its visibility, TTL and size limit.

## Startup errors

hybrids3 checks `config.yaml` before it serves anything. On a problem it logs one `ERROR` line and exits with status 1, so the container stops or restarts in a loop. The messages come from [`app/config.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/config.py):

| Message | Cause | Fix |
| --- | --- | --- |
| `Config file not found: /config/config.yaml` | Nothing is mounted at that path | Mount the file with `-v ./config.yaml:/config/config.yaml:ro`. With a relative host path, run the command from the directory that holds the file |
| `Config file is empty: /config/config.yaml` | The file is empty or holds only comments | Fill in the file |
| `Invalid bucket name '<name>': must not contain '/' or '..'` | A bucket name has a slash, two dots or is empty | Rename the bucket |
| `Bucket '<name>' has no key configured` | A bucket has no `key` or an empty one | Add a `key` |
| `No buckets configured` | `buckets` is missing or empty | Define at least one bucket |
| `Invalid TTL value: <value>` | `ttl` or `cleanup_interval` is not a [duration](configuration.md#durations) | Use a form such as `30s`, `1h` or `2d12h`, or a number of seconds |
| `Invalid size value: <value>` | `max_file_size` does not look like a number and a unit | Use a form such as `50MB` or a number of bytes |
| `Unknown size unit '<unit>' in: <value> (use B, KB, MB, GB, TB)` | The unit is not one of those five | Use one of the listed units |

An `IsADirectoryError` traceback means the host file did not exist when the container started, so Docker created a directory in its place. Remove that directory, create the file and start again. A `PermissionError` traceback at startup means `/data` is not writable by UID 1000; see [File ownership](deployment.md#file-ownership).

## Requests

### 404 NoSuchBucket for a bucket that exists

hybrids3 answers `404` instead of `401` or `403` when the key does not fit the bucket, so missing and forbidden look the same from outside. Check that:

- the Bearer token is the bucket's `key` (or the master key), not its `public_key`;
- an S3 client uses the bucket's `public_key` as access key ID and `key` as secret, and talks to that bucket only;
- the container was restarted after the configuration changed.

The log line for the request shows `status: 404` and the bucket name.

### 403 AccessDenied

`GET /` without a valid key, or a presigned GET URL that is expired, altered or used with a different host than it was created for.

### 503 ServiceUnavailable or RequestTimeout

The per-object lock refused the request:

- `ServiceUnavailable`: more than `lock_max_waiters` requests were already waiting for that object.
- `RequestTimeout`: the request waited longer than `lock_acquire_timeout` for the lock, or held it longer than `lock_hold_timeout`. Long uploads over slow links hit the hold timeout; raise it.

[Locking](storage.md#locking) has the details.

### 413 EntityTooLarge

The object is larger than the bucket's `max_file_size`. When a proxy answers `413` with an HTML page instead, the proxy's own limit fired; set `client_max_body_size 0` in nginx.

### Every S3 call gets 404 through a proxy

hybrids3 reports a failed signature check as `404 NoSuchBucket`, like any other auth failure. The usual cause is that the path or `Host` the client signed differs from what hybrids3 received. Behind a proxy at a subpath, set `path_prefix`, forward the path unchanged and pass `Host $http_host`. [Behind a reverse proxy](reverse-proxy.md) shows a working nginx block. Also check that `endpoint_url` includes the prefix.

### Presigned URLs start with http:// behind HTTPS

uvicorn ignores `X-Forwarded-Proto` from the proxy until you set `FORWARDED_ALLOW_IPS`. See [HTTPS and presigned URLs](reverse-proxy.md#https-and-presigned-urls).

### The stored content type is wrong

A client-supplied `Content-Type` wins unless it is generic. Clients that send a specific but wrong type get it stored as sent. Send the right header, or none and let hybrids3 [detect it](storage.md#mime-type-detection).

### boto3 upload_file or aws s3 cp fails on large files

Both switch to multipart uploads above a size threshold, and hybrids3 has no multipart support. Use `put_object` or `aws s3api put-object`.

### An object became empty after copy_object

`CopyObject` is not supported, and the request is handled as an upload with an empty body. Download and upload the object instead.

### MCP: Missing session ID

A raw JSON-RPC call has to start a session with `initialize` first. See [Calling it without a client](mcp.md#calling-it-without-a-client).

### Objects disappear

Either the bucket has a `ttl`, or files were copied into a bucket directory by hand and the cleanup loop removed them as orphans. See [Cleanup loop](storage.md#cleanup-loop).
