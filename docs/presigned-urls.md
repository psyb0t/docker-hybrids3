---
title: "Presigned URLs"
description: "Hand out time-limited hybrids3 links that let someone download or upload one object without a key, from the HTTP endpoint, the MCP tool or boto3."
nav_order: 8
---

# Presigned URLs

A presigned URL lets anyone who has the link perform one action on one object until it expires, without an `Authorization` header. Use a presigned GET to share a file from a private bucket, and a presigned PUT to let a client upload a file without ever seeing your bucket key.

hybrids3 uses the AWS Signature V4 query format, so URLs from hybrids3 and URLs from boto3 are interchangeable.

## Creating one over HTTP

`POST /presign/{bucket}/{key}` needs the bucket key or the master key.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `method` | `GET` | `GET` to download or `PUT` to upload. Anything else gets `400 InvalidArgument` |
| `expires` | `3600` | Lifetime in seconds, clamped to 1 to 604800 (7 days). A non-integer gets `400 InvalidArgument` |

```bash
curl -X POST "http://localhost:8080/presign/permanent/doc.pdf?expires=3600" \
  -H "Authorization: Bearer perm-secret"
```

```json
{
  "url": "http://localhost:8080/permanent/doc.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=permanent-id%2F20261110%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20261110T071856Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=...",
  "method": "GET",
  "expires": 3600
}
```

The URL carries the bucket's `public_key` in `X-Amz-Credential` and an HMAC in `X-Amz-Signature`. The private key signs it on the server and never appears in it.

## GET on a public bucket

A public bucket needs no key to read, so hybrids3 returns a plain URL without a signature or expiry:

```bash
curl -X POST "http://localhost:8080/presign/uploads/photo.jpg" \
  -H "Authorization: Bearer uploads-secret"
```

```json
{
  "url": "http://localhost:8080/uploads/photo.jpg",
  "method": "GET",
  "expires": null
}
```

## Presigned PUT

Public buckets allow anonymous reads, never anonymous writes, so a presigned PUT is always signed, also on a public bucket:

```bash
curl -X POST "http://localhost:8080/presign/uploads/inbox/report.pdf?method=PUT&expires=600" \
  -H "Authorization: Bearer uploads-secret"
```

The recipient uploads with the URL alone:

```bash
curl -X PUT "<url>" --data-binary @report.pdf
```

The bucket's `max_file_size` still applies and an oversized body gets `413`. The upload replaces any object already stored under that key.

## Creating one over MCP or boto3

The `presign_url` [MCP tool](mcp.md#presign_url) follows the same rules. Pass `method="PUT"` for an upload URL and always pass `base_url`, since the MCP server cannot know the address clients use.

boto3 signs URLs on the client with the bucket's key pair:

```python
get_url = s3.generate_presigned_url(
    "get_object",
    Params={"Bucket": "permanent", "Key": "doc.pdf"},
    ExpiresIn=3600,
)

put_url = s3.generate_presigned_url(
    "put_object",
    Params={"Bucket": "uploads", "Key": "inbox/report.pdf"},
    ExpiresIn=600,
)
```

## What a URL allows

- One HTTP method. The method is part of the signature, so a GET URL cannot upload and a PUT URL cannot download.
- One key in one bucket. Changing the path breaks the signature.
- One host. The URL signs the `Host` header, so it only works when requested with the host it was created for. hybrids3 uses the `Host` header of the request that created it; behind a proxy that has to be the public host, which is why the [reverse proxy](reverse-proxy.md) setup passes `$http_host`.
- Until it expires. A GET URL used after `X-Amz-Date` plus `X-Amz-Expires` gets `403 AccessDenied`; an expired or altered PUT URL gets `404 NoSuchBucket`, like any failed write.

There is no way to revoke a single URL. Rotating the bucket key in the configuration and restarting invalidates every URL that key signed.

The 7-day cap applies to URLs that hybrids3 creates. A URL signed by a client that holds the key is checked against its own `X-Amz-Expires` with no upper limit, and a signed URL without `X-Amz-Expires` never expires.

## Scheme behind TLS

hybrids3 builds the URL from the scheme and host it sees. Behind a TLS proxy it sees plain HTTP unless uvicorn trusts the proxy's `X-Forwarded-Proto` header. [Behind a reverse proxy](reverse-proxy.md#https-and-presigned-urls) shows the setting.
