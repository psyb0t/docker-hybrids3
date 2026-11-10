---
title: "Security"
description: "What hybrids3 protects, what it stores, the gaps to know about, and the checklist to work through before exposing it beyond localhost."
nav_order: 12
---

# Security

hybrids3 is meant to sit on a private network or behind a TLS proxy, holding files for services and agents you control. This page lists what it does to protect them, where it falls short, and what to set before anyone else can reach it.

## Before exposing it

- Replace every key from `config.example.yaml`. They are published.
- Bind the port to `127.0.0.1` or keep it on an internal Docker network, and put a TLS proxy in front for remote clients. hybrids3 itself speaks plain HTTP, so keys in Bearer headers and MCP `auth_key` arguments travel in the clear without TLS.
- Treat every `public: true` bucket as readable by the whole network.
- Give clients bucket keys. Keep the master key for administration, or leave `master_key` empty.
- Pick bucket names other than `docs`, `redoc` and `openapi.json`, which FastAPI serves itself.
- Protect `config.yaml` like a password file. It holds every key in plain text.

## What is protected

- **Signature checks.** S3 requests and presigned URLs are verified with AWS Signature V4. The `public_key` only identifies the bucket; the signature has to match the private key.
- **Constant-time comparison.** Every key comparison uses `hmac.compare_digest`.
- **Keys stay on the server.** No response or presigned URL contains a private key, and hybrids3 never logs one. MCP `list_buckets` returns names and settings only.
- **Hidden buckets.** Unauthorized access gets the same `404` as a missing bucket. See [Keys and access](keys-and-access.md#hidden-buckets) for the exceptions.
- **Path traversal.** Every key is resolved against its bucket directory and refused with `400` if it would land outside.
- **Prefix filters.** `%`, `_` and `\` in a listing `prefix` are escaped before they reach SQLite's `LIKE`.
- **Atomic writes and streaming.** Uploads go to a temporary file and are renamed into place. Bodies stream to disk instead of memory, and `max_file_size` stops them early.
- **Bounded waiting.** Per-object locks have a queue limit and timeouts, so a flood on one key gets `503` instead of piling up.
- **MCP limits.** Tool errors hide exception details, and downloads over 50 MB are refused.
- **Non-root container.** The process runs as UID 1000 and writes only `/data`.
- **`X-Content-Type-Options: nosniff`** on every response, so browsers do not guess a different type for stored files.

## Known gaps

These follow from the code as it is today:

- **No replay window for signed requests.** hybrids3 does not compare `X-Amz-Date` with the clock on header-signed requests. A captured signed request can be sent again later.
- **Body checksums are not verified.** The `x-amz-content-sha256` value is part of the signature, but nothing checks it against the body. Someone who captures a signed PUT could resend it with a different body. TLS prevents both this and the replay above.
- **Client-signed presigned URLs are not capped.** URLs that hybrids3 generates expire within 7 days. A URL signed by a client holding the key is trusted for whatever `X-Amz-Expires` it carries, and one without `X-Amz-Expires` never expires.
- **No revocation.** A leaked key or presigned URL stays valid until you rotate that key in the configuration and restart.
- **Bucket names can be probed.** `GET /<bucket>?location` answers `200` for any configured bucket without a key.
- **The MCP connection token is optional and grants nothing.** Requests without a token pass, and a valid token does not limit the tools. With `path_prefix` set, wrong tokens are not rejected either. Per-tool `auth_key` checks are what protect the data.
- **The access log prints query strings.** uvicorn logs every request line, query string included. An MCP token sent as `?auth=<key>` and the signatures of presigned URLs end up in `docker logs`. Prefer the `Authorization` header for MCP clients that can send one.
- **No rate limiting.** Wrong keys can be tried as fast as the server answers. Put rate limits in the proxy.
- **FastAPI's API pages are public.** `/docs`, `/redoc` and `/openapi.json` answer without a key and describe the HTTP routes.
- **No encryption at rest and no CORS headers.** Use disk encryption on the host, and add CORS at the proxy if browsers need it.

## What is stored

| Data | Where |
| --- | --- |
| Keys | `config.yaml`, plain text, never written anywhere else |
| Object bytes | `/data/<bucket>/<key>`, unencrypted |
| Object metadata | `/data/hybrids3.db`: key names, sizes, content types, MD5 ETags and timestamps |
| Logs | stdout: request IDs, bucket names, object keys, sizes and error codes, plus uvicorn's access log with every request line. No object content |

Object keys are logged, so do not put secrets in key names.

## Reporting a problem

Open an issue on [GitHub](https://github.com/psyb0t/docker-hybrids3/issues). Pull requests are closed automatically.
