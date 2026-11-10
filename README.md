# HybridS3

[![CI](https://github.com/psyb0t/docker-hybrids3/actions/workflows/pipeline.yml/badge.svg?branch=main)](https://github.com/psyb0t/docker-hybrids3/actions/workflows/pipeline.yml)
[![version](https://raw.githubusercontent.com/psyb0t/docker-hybrids3/badges/version.svg)](https://github.com/psyb0t/docker-hybrids3/releases)
[![license](https://raw.githubusercontent.com/psyb0t/docker-hybrids3/badges/license.svg)](https://github.com/psyb0t/docker-hybrids3/blob/main/LICENSE)
[![Docker Pulls](https://img.shields.io/docker/pulls/psyb0t/hybrids3?style=flat-square)](https://hub.docker.com/r/psyb0t/hybrids3)

Lightweight object storage that speaks S3 (boto3/AWS SDK compatible), plain HTTP, and MCP. SQLite for metadata, flat files on disk.

**Documentation: https://psyb0t.github.io/docker-hybrids3/**

## Table of contents

- [Why](#why)
- [Quick start](#quick-start)
- [Three ways in](#three-ways-in)
- [Documentation](#documentation)
- [Development](#development)
- [Limitations](#limitations)
- [Sponsor](#sponsor)
- [License](#license)

## Why

**Most self-hosted S3-compatible storage is built for large deployments.** Distributed erasure coding, IAM policies, WORM compliance, full web consoles. Useful if you run a cloud, overkill if you just want a place to put files that a few services and AI agents can read and write.

**AWS Sig V4 breaks behind reverse proxy path prefixes.** Put most implementations behind nginx at `/storage/`, nginx strips the prefix, the server sees `/bucket/key` while the client signed `/storage/bucket/key`, and every signature check fails. hybrids3 has a `path_prefix` setting: set it to `/storage`, every route moves under it, the proxy forwards the path untouched and the signatures match.

**Three interfaces, one service.** boto3 works out of the box. `curl` with a Bearer token works. AI agents connect over MCP and get typed tools. One container, one port.

**Buckets are configuration, not state.** There is no API to create or delete a bucket. Buckets live in the YAML config, so you always know exactly what exists, it's version-controlled, and no surprise buckets pile up garbage.

**TTL expiry is built in.** Set `ttl: 24h` on a bucket and objects expire 24 hours after their last write. No lifecycle policies, no cron jobs.

**Small enough to read in an afternoon.** Thirteen Python modules.

## Quick start

```bash
# get the example config, then change every key in it
wget -O config.yaml \
  https://raw.githubusercontent.com/psyb0t/docker-hybrids3/main/config.example.yaml

docker run -d --name hybrids3 \
  -p 127.0.0.1:8080:8080 \
  -v ./config.yaml:/config/config.yaml:ro \
  -v hybrids3-data:/data \
  psyb0t/hybrids3

curl http://localhost:8080/health
```

The container reads `/config/config.yaml`, keeps everything in `/data` and runs as UID 1000. [Running the container](https://psyb0t.github.io/docker-hybrids3/deployment/) covers Compose, upgrades and backups, and [Configuration](https://psyb0t.github.io/docker-hybrids3/configuration/) lists every setting.

## Three ways in

Plain HTTP with a Bearer token. Public buckets need no token to read:

```bash
curl -X PUT http://localhost:8080/uploads/file.txt \
  -H "Authorization: Bearer uploads-secret" \
  --data-binary "hello"

curl http://localhost:8080/uploads/file.txt
```

boto3, with the bucket's `public_key` as access key ID and its `key` as secret:

```python
import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:8080",
    aws_access_key_id="uploads-id",
    aws_secret_access_key="uploads-secret",
    region_name="us-east-1",
    config=Config(signature_version="s3v4"),
)
s3.put_object(Bucket="uploads", Key="file.txt", Body=b"hello")
```

MCP, Streamable HTTP at `/mcp/`, with seven tools for uploading, downloading, listing, deleting and presigning:

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

There is also an agent skill and plugin for Claude Code, Codex and OpenClaw; see [Agent integrations](https://psyb0t.github.io/docker-hybrids3/agent-integrations/).

## Documentation

The full documentation lives at **https://psyb0t.github.io/docker-hybrids3/**.

| Page | What it covers |
| --- | --- |
| [Running the container](https://psyb0t.github.io/docker-hybrids3/deployment/) | Tags, mounts, Compose, file ownership, upgrades, backups |
| [Configuration](https://psyb0t.github.io/docker-hybrids3/configuration/) | Every `config.yaml` setting with defaults and formats |
| [Keys and access](https://psyb0t.github.io/docker-hybrids3/keys-and-access/) | Bucket key pairs, the master key, public and private buckets |
| [HTTP API](https://psyb0t.github.io/docker-hybrids3/http-api/) | Routes, headers, status codes and error codes |
| [S3 API](https://psyb0t.github.io/docker-hybrids3/s3-api/) | Signature V4, boto3, aws-cli and supported operations |
| [MCP server](https://psyb0t.github.io/docker-hybrids3/mcp/) | Client setup, auth layers and every tool |
| [Presigned URLs](https://psyb0t.github.io/docker-hybrids3/presigned-urls/) | Time-limited GET and PUT links |
| [Storage, expiry and locking](https://psyb0t.github.io/docker-hybrids3/storage/) | MIME detection, TTL, cleanup and per-object locks |
| [Behind a reverse proxy](https://psyb0t.github.io/docker-hybrids3/reverse-proxy/) | `path_prefix`, nginx and https presigned URLs |
| [Agent integrations](https://psyb0t.github.io/docker-hybrids3/agent-integrations/) | Skill and plugins for Claude Code, Codex and OpenClaw |
| [Security](https://psyb0t.github.io/docker-hybrids3/security/) | What is protected, known gaps, checklist before exposing it |
| [Troubleshooting](https://psyb0t.github.io/docker-hybrids3/troubleshooting/) | Log format, startup errors and common failures |
| [Architecture](https://psyb0t.github.io/docker-hybrids3/architecture/) | Modules and the path of a request |
| [Development](https://psyb0t.github.io/docker-hybrids3/development/) | Dev container, tests, dependencies, CI and releases |

## Development

All tooling runs in a sandboxed dev container, so the host needs only Docker, Make, Bash and curl.

```bash
make help       # every target
make lint       # flake8 + mypy
make test       # production image, unit tests and the integration suite
make build      # production image
make docs       # build the documentation site locally
```

Dependency changes go through `make pkg-add`, `pkg-remove`, `pkg-update` and `pkg-upgrade`, which move the supply-chain age gate in [`pyproject.toml`](https://github.com/psyb0t/docker-hybrids3/blob/main/pyproject.toml) together with the lockfile. [Development](https://psyb0t.github.io/docker-hybrids3/development/) has the details, and [`AGENTS.md`](https://github.com/psyb0t/docker-hybrids3/blob/main/AGENTS.md) is the guide for coding agents.

## Limitations

No multipart upload, no object versioning, no ACLs beyond bucket-level public/private, no bucket creation or deletion through the API, no CORS headers, no replication and no encryption at rest. Listings stop at 1000 objects.

## Sponsor

<a href="https://www.buymeacoffee.com/psyb0t"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-blue.png" alt="Buy Me a Coffee" height="60" width="217"></a>

## License

[WTFPL](https://github.com/psyb0t/docker-hybrids3/blob/main/LICENSE)
