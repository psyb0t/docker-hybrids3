---
title: "Running the container"
description: "Run the psyb0t/hybrids3 image with docker run or Compose: tags, the config and data mounts, UID 1000 ownership, health checks, upgrades and backups."
nav_order: 2
---

# Running the container

hybrids3 ships as one image, `psyb0t/hybrids3` on Docker Hub, built for `linux/amd64` and `linux/arm64`. It needs a configuration file and a data directory, and listens on port 8080.

## What the container expects

| Path or port | Purpose |
| --- | --- |
| `/config/config.yaml` | The [configuration](configuration.md). Mount it read-only. The path is fixed in [`app/main.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/main.py) |
| `/data` | SQLite metadata and object files. Mount a volume here or everything is lost with the container |
| `8080` | HTTP API, S3 API and MCP, all on the same port. Plain HTTP, no TLS |

The process runs as user `hybrids3`, UID 1000 and GID 1000. hybrids3 itself reads no environment variables; everything is in `config.yaml`. The one variable worth knowing belongs to uvicorn, the HTTP server: `FORWARDED_ALLOW_IPS` decides whose `X-Forwarded-Proto` header to trust, which matters for presigned URLs behind a TLS proxy. [Behind a reverse proxy](reverse-proxy.md#https-and-presigned-urls) explains it.

## Image tags

| Tag | What it points at |
| --- | --- |
| `latest` | The newest build of `main` |
| `vX.Y.Z` | A release. The release tag points at the same image digest that `main` built for that commit; nothing is rebuilt |
| `sha-<commit>` | The build of one `main` commit |

Pin a `vX.Y.Z` tag in production so an upgrade is a decision.

## docker run

```bash
docker run -d --name hybrids3 \
  -p 127.0.0.1:8080:8080 \
  -v ./config.yaml:/config/config.yaml:ro \
  -v hybrids3-data:/data \
  --restart unless-stopped \
  psyb0t/hybrids3
```

`-p 127.0.0.1:8080:8080` makes the port reachable from this host only. `-p 8080:8080` publishes it on every interface, which also exposes every `public: true` bucket to anyone who can reach the host. For access from other machines, put hybrids3 behind a [reverse proxy](reverse-proxy.md) with TLS.

## Docker Compose

```yaml
services:
  hybrids3:
    image: psyb0t/hybrids3
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./config.yaml:/config/config.yaml:ro
      - hybrids3-data:/data
    restart: unless-stopped

volumes:
  hybrids3-data:
```

When a reverse proxy runs in the same Compose project, drop `ports` and let the proxy reach `hybrids3:8080` over the Compose network.

## File ownership

A named volume such as `hybrids3-data` takes its ownership from the image, where `/data` belongs to UID 1000, so it works as is. A bind mount keeps the host directory's ownership, so give it to UID 1000 first:

```bash
mkdir -p ./data
sudo chown 1000:1000 ./data
```

Without that, startup fails with a permission error while creating the bucket directories or the database.

## What lives in /data

| Path | Contents |
| --- | --- |
| `/data/hybrids3.db` | SQLite database (WAL mode) with one row per object: bucket, key, content type, size, MD5 ETag, upload time and expiry time |
| `/data/hybrids3.db-wal`, `/data/hybrids3.db-shm` | SQLite write-ahead log files. They belong to the database |
| `/data/<bucket>/<key>` | The object bytes. Nested keys such as `reports/2024/jan.pdf` become nested directories |

hybrids3 creates a directory for every configured bucket at startup. Files and rows that belong to a bucket you later remove from the configuration stay on disk. Orphan cleanup only scans configured buckets, while TTL expiry still deletes expired rows and files of a removed bucket. Delete `/data/<bucket>` yourself once you no longer need it.

## Health check

`GET /health` answers `{"status":"ok"}` with `200` and needs no key. Behind a `path_prefix` it moves to `<prefix>/health`. The image defines no Docker `HEALTHCHECK` and has no `curl`, so a Compose health check has to use Python:

```yaml
    healthcheck:
      test:
        - CMD
        - python
        - -c
        - "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"
      interval: 30s
      timeout: 5s
      retries: 3
```

## Changing the configuration

hybrids3 reads `config.yaml` once, at startup. Adding a bucket, rotating a key or changing a limit takes a restart:

```bash
docker restart hybrids3
```

An invalid file stops the container with an error in `docker logs`. [Troubleshooting](troubleshooting.md#startup-errors) lists each message.

## Upgrades

```bash
docker pull psyb0t/hybrids3
docker rm -f hybrids3
```

Then start it again with the same `docker run` command, or run `docker compose pull && docker compose up -d`. The database schema is created with `CREATE TABLE IF NOT EXISTS`, so a new image opens the existing `/data` as is. Read the [CHANGELOG](https://github.com/psyb0t/docker-hybrids3/blob/main/CHANGELOG.md) before moving between releases.

## Backups

The database and the object files have to match, so copy them together while nothing writes. The simplest consistent backup stops the container for the copy:

```bash
docker stop hybrids3
docker run --rm \
  -v hybrids3-data:/data:ro \
  -v "$PWD:/backup" \
  alpine tar czf /backup/hybrids3-data.tgz -C /data .
docker start hybrids3
```

Restore by extracting the archive into an empty volume before starting the container. Keep `config.yaml` with the backup, since it holds the bucket definitions and keys.

## Logs

hybrids3 writes one JSON object per line to stdout, so `docker logs -f hybrids3` shows them. [Troubleshooting](troubleshooting.md#log-format) describes the fields.
