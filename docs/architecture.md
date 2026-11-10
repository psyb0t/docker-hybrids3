---
title: "Architecture"
description: "How hybrids3 is built: the FastAPI app and its middlewares, the modules in app/, the path of an upload and how HTTP, S3 and MCP share one store."
nav_order: 14
---

# Architecture

hybrids3 is one Python process: a FastAPI application served by uvicorn on port 8080, with a FastMCP server mounted inside it and a background cleanup task. HTTP, S3 and MCP requests all end up in the same storage functions, the same SQLite connection and the same lock table, so an object written through one interface is visible through the others at once.

## Modules

All code is in [`app/`](https://github.com/psyb0t/docker-hybrids3/tree/main/app), as flat modules that import each other by name.

| Module | Job |
| --- | --- |
| `main.py` | Builds the app, loads the configuration at startup, opens the database, wires the other modules, mounts MCP at `/mcp`, adds the middlewares and starts the cleanup task |
| `config.py` | Parses and validates `config.yaml` into `AppConfig` and `BucketConfig` |
| `routes.py` | HTTP and S3 routes, the presign endpoint, auth checks and the JSON or XML error format |
| `auth.py` | Bearer token checks and SigV4 header or presigned URL checks |
| `sigv4.py` | AWS Signature V4 parsing, verification and presigned URL generation |
| `mcp_server.py` | The seven MCP tools |
| `lock.py` | Per-object async read-write locks with timeouts and a queue limit |
| `storage.py` | Safe path resolution, atomic writes, reads, deletes and the on-disk listing |
| `db.py` | The SQLite `objects` table |
| `scheduler.py` | The cleanup loop for expired objects and orphan files |
| `mimetype.py` | libmagic detection with an extension fallback |
| `s3xml.py` | S3 XML response documents |
| `logger.py` | JSON log lines with the request ID |

## Middlewares

Every request passes three middlewares before it reaches a route, in this order:

1. `RequestIdMiddleware` creates the request ID, stores it for the logger and adds `X-Request-Id` and `X-Content-Type-Options: nosniff` to the response.
2. `McpAuthMiddleware` checks the optional MCP connection token on paths that start with `/mcp`.
3. `PathPrefixMiddleware` handles `path_prefix`. It refuses paths outside the prefix with `404`, strips the prefix so the routes match, and keeps the original path for the signature check.

## An upload, step by step

```text
client
  -> RequestIdMiddleware        request ID
  -> McpAuthMiddleware          (only /mcp paths)
  -> PathPrefixMiddleware       strip path_prefix, keep the signed path
  -> routes.put_object
       _get_bucket              404 if the bucket is not configured
       _check_write_auth        Bearer or SigV4, 404 if neither fits
       storage.write_path       resolve the key, 400 if it escapes the bucket
       LockManager.write        per-object lock, 503 on queue or timeout
       stream body to <name>.tmp.<hex>, 413 past max_file_size
       rename onto the final path
       MD5 ETag, MIME detection
       db.upsert_object         metadata row with expiry time
  <- 200 with ETag
```

An MCP `upload_object` call skips the routes and runs the same steps from `mcp_server.py`, after checking its `auth_key`.

## How the three interfaces differ

| | HTTP | S3 | MCP |
| --- | --- | --- | --- |
| Entry point | `routes.py` | `routes.py` | `mcp_server.py` |
| Credential | Bearer token | SigV4 signature | `auth_key` argument |
| Response | JSON | XML | JSON-RPC result with a JSON object |
| Unauthorized | `404` | `404` | `"Bucket '<name>' does not exist"` |

`routes.py` decides between JSON and XML per request: an `AWS4-HMAC-SHA256` Authorization header or any `x-amz-*` header means S3.

## State

All state is in `/data`: object files under `/data/<bucket>/` and the `objects` table in `/data/hybrids3.db`. Configuration is read once at startup and kept in memory. Locks live in memory too and disappear with the process, which is fine because they only cover requests in flight. [Storage, expiry and locking](storage.md#metadata-table) shows the table.

## Concurrency

uvicorn runs one worker process with one event loop. SQLite calls and file hashing are synchronous and run on that loop, so they serialize with each other. Body streaming and lock waits are asynchronous, so many requests can be in flight at once. Running more than one container on the same `/data` is not supported: the locks are per process.
