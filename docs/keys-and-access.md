---
title: "Keys and access"
description: "How hybrids3 authenticates: per-bucket private and public keys, the cross-bucket master key, public versus private buckets, and the 404 for hidden buckets."
nav_order: 4
---

# Keys and access

Every credential in hybrids3 comes from [`config.yaml`](configuration.md). Each bucket has its own key pair, and one optional master key works everywhere. The same keys work over all three interfaces: HTTP, S3 and MCP.

## Bucket key pair

| Setting | Role | Secret? |
| --- | --- | --- |
| `key` | The private key. Over HTTP it is the Bearer token. Over S3 it is the `aws_secret_access_key` that signs requests. Over MCP it is the `auth_key` tool argument | Yes |
| `public_key` | The identifier S3 clients send as `aws_access_key_id`. It also appears in presigned URLs. It grants nothing without a valid signature | No |

The split is what makes presigned URLs safe. A presigned URL has to say which key signed it, so it carries the `public_key` in `X-Amz-Credential`. The private key computes the signature on the server and never appears in the URL.

A bucket key only works on its own bucket. Using one bucket's key on another bucket gets the same `404` as a bucket that does not exist.

## Master key

`master_key` works on every bucket for every operation. It is also the only credential that lists all buckets; a bucket key lists only its own bucket. Its S3 identifier is `master_public_key`, `master` by default.

Use it for administration and for clients that really need several buckets. Give everything else a bucket key, so a leaked key exposes one bucket. Leave `master_key` empty to turn the master key off.

## Public and private buckets

| Bucket | GET, HEAD, list | PUT | DELETE, presign |
| --- | --- | --- | --- |
| `public: true` | anyone, no key | bucket key, master key or presigned PUT URL | bucket key or master key |
| `public: false` | bucket key, master key or presigned GET URL | bucket key, master key or presigned PUT URL | bucket key or master key |

A public bucket is readable by anyone who can reach the port. Anonymous writes are never allowed, on any bucket.

## How each interface sends the key

| Interface | How |
| --- | --- |
| HTTP | `Authorization: Bearer <key>` |
| S3 | AWS Signature V4 with `public_key` as the access key ID and `key` as the secret. See [S3 API](s3-api.md#authentication) |
| MCP | The `auth_key` argument of each tool, plus an optional connection token. See [MCP server](mcp.md#authentication) |
| Presigned URL | The signature in the query string. See [Presigned URLs](presigned-urls.md) |

## Hidden buckets

A request for a bucket the caller may not see gets `404 NoSuchBucket`, the same answer as a bucket that does not exist, so a caller without a key cannot find out which buckets exist. The exceptions:

- `GET /` without a valid key gets `403 AccessDenied`.
- A presigned GET URL with a bad or expired signature gets `403 AccessDenied`. A bad presigned PUT URL gets the usual `404`.
- `GET /<bucket>?location` answers `200` for any configured bucket without checking a key, so it does reveal whether a bucket name exists. See [Security](security.md#known-gaps).

All key comparisons use `hmac.compare_digest`, which takes the same time whether the first byte or the last byte differs.
