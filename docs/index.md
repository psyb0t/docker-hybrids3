---
title: "Home"
description: "hybrids3 is a self-hosted object storage container that answers boto3 and AWS SDKs, curl with Bearer tokens, and AI agents over MCP on one port."
nav_order: 1
permalink: /
seo:
  type: WebSite
---

# HybridS3

hybrids3 is object storage in one small container. The same process answers the S3 API (AWS Signature V4, so boto3 and the AWS SDKs work unchanged), a plain HTTP API you can drive with `curl` and a Bearer token, and an [MCP](https://modelcontextprotocol.io/) server that AI agents call as typed tools. Metadata lives in SQLite, object bytes are plain files on disk.

Buckets are configuration, not state. You list them in a YAML file with their keys, visibility, expiry and size limit, and nothing can create or delete one at runtime. What the file says is what exists.

## Quick start

Get the example configuration and change every key in it:

```bash
wget -O config.yaml \
  https://raw.githubusercontent.com/psyb0t/docker-hybrids3/main/config.example.yaml
```

Run the container, bound to loopback:

```bash
docker run -d --name hybrids3 \
  -p 127.0.0.1:8080:8080 \
  -v ./config.yaml:/config/config.yaml:ro \
  -v hybrids3-data:/data \
  psyb0t/hybrids3
```

Check it and store something. With the example configuration, `uploads` is a public bucket whose key is `uploads-secret`:

```bash
curl http://localhost:8080/health

curl -X PUT http://localhost:8080/uploads/hello.txt \
  -H "Authorization: Bearer uploads-secret" \
  --data-binary "hello"

curl http://localhost:8080/uploads/hello.txt
```

[Running the container](deployment.md) covers Compose, volumes, upgrades and backups.

## What is on this site

| Page | What it covers |
| --- | --- |
| [Running the container](deployment.md) | Image tags, mounts, Compose, file ownership, upgrades, backups and what lives in `/data` |
| [Configuration](configuration.md) | Every setting in `config.yaml`, with defaults, formats and startup errors |
| [Keys and access](keys-and-access.md) | Bucket keys, public keys, the master key and what public and private buckets allow |
| [HTTP API](http-api.md) | Every route, query parameter, header, status code and error code |
| [S3 API](s3-api.md) | Signature V4, boto3 and aws-cli setup, and which S3 operations work |
| [MCP server](mcp.md) | Connecting a client, the two auth layers and the seven tools |
| [Presigned URLs](presigned-urls.md) | Handing out time-limited GET and PUT links for one object |
| [Storage, expiry and locking](storage.md) | MIME detection, TTL expiry, orphan cleanup and per-object locks |
| [Behind a reverse proxy](reverse-proxy.md) | Serving under a path prefix with nginx without breaking signatures |
| [Agent integrations](agent-integrations.md) | The skill and plugins for Claude Code, Codex and OpenClaw |
| [Security](security.md) | What is protected, what is not, and what to set before exposing it |
| [Troubleshooting](troubleshooting.md) | Log format, startup errors, `503` responses and signature mismatches |
| [Architecture](architecture.md) | Modules, the request path and the metadata table |
| [Development](development.md) | The dev container, tests, dependency changes, CI and releases |

## Limitations

hybrids3 is built for a handful of services and agents sharing one store, not for a cloud. It has no multipart upload, no object versioning, no ACLs beyond public or private buckets, no CORS headers, no replication and no encryption at rest. Listings return at most 1000 objects with no continuation. Each limit is described on the page it affects.
