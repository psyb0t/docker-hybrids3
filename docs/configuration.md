---
title: "Configuration"
description: "Every hybrids3 config.yaml setting: master key, cleanup interval, lock limits, path prefix and per-bucket keys, visibility, TTL and size limit."
nav_order: 3
---

# Configuration

hybrids3 reads one YAML file, `/config/config.yaml`, at startup. It defines the master key, a few server settings and every bucket. There is no other configuration and no environment variable for any of this. Change the file and restart the container to apply a change.

The annotated example is [`config.example.yaml`](https://github.com/psyb0t/docker-hybrids3/blob/main/config.example.yaml), and the parser is [`app/config.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/config.py).

## Example

```yaml
master_key: "change-me-to-something-secret"
master_public_key: "master"
cleanup_interval: 1m
lock_acquire_timeout: 30
lock_hold_timeout: 300
lock_max_waiters: 100
# path_prefix: /storage

buckets:
  uploads:
    public: true
    key: "uploads-secret"
    public_key: "uploads-id"
    ttl: 24h
    max_file_size: 50MB

  permanent:
    public: false
    key: "perm-secret"
    public_key: "permanent-id"
    ttl: 0
    max_file_size: 100MB
```

Replace every key before you expose the server. The example keys are public.

## Top-level settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `master_key` | `""` | Secret that works on every bucket for every operation and is the only key that lists all buckets. Empty disables the master key. See [Keys and access](keys-and-access.md#master-key) |
| `master_public_key` | `"master"` | Non-secret `aws_access_key_id` that pairs with `master_key` for S3 clients |
| `cleanup_interval` | `60` | Time between runs of the cleanup loop that deletes expired objects and orphan files. A [duration](#durations) or a number of seconds. Use a value above zero |
| `lock_acquire_timeout` | `30` | Seconds a request waits for the lock on one object before it gets `503`. Decimals allowed |
| `lock_hold_timeout` | `300` | Seconds a request may hold the lock on one object. When it runs out, the lock is released and the request gets `503`. Raise it if large uploads over slow links take longer |
| `lock_max_waiters` | `100` | Requests that may wait for the same object at once. The next one gets `503` immediately |
| `path_prefix` | `""` | Serve every route under this path, for a [reverse proxy](reverse-proxy.md) at a subpath. `/storage`, `/storage/` and `storage` all become `/storage`. Empty serves at the root |
| `buckets` | none | Map of bucket name to bucket settings. At least one bucket is required |

[Storage, expiry and locking](storage.md#locking) explains the three lock settings.

## Bucket settings

Each entry under `buckets` is keyed by the bucket name. A name must not be empty and must not contain `/` or `..`. S3 clients use path-style URLs (`http://host:8080/<bucket>/<key>`), so names do not have to be valid DNS labels, but lowercase letters, digits and hyphens keep every client happy.

| Setting | Default | Meaning |
| --- | --- | --- |
| `key` | required | The bucket's private key. It is the Bearer token for HTTP and MCP and the `aws_secret_access_key` for S3. Keep it secret |
| `public` | `false` | `true` lets anyone read (GET, HEAD, list) without a key. Writes, deletes and presigning always need a key. Write it as an unquoted YAML boolean |
| `public_key` | the bucket name | Non-secret `aws_access_key_id` for this bucket. It appears in signed request headers and presigned URLs. Keep it unique across buckets and different from `master_public_key` |
| `ttl` | `0` | Objects expire this long after their last write. `0` keeps them forever. A [duration](#durations) or a number of seconds. See [TTL expiry](storage.md#ttl-expiry) |
| `max_file_size` | `0` | Largest object accepted, as a [size](#sizes) or a number of bytes. Bigger uploads get `413`. `0` means no limit |

Unknown settings are ignored without a warning, so check the spelling of anything that seems to have no effect.

## Durations

`ttl` and `cleanup_interval` accept a number of seconds (`86400`) or a duration string parsed by [pytimeparse2](https://pypi.org/project/pytimeparse2/): `30s`, `5m`, `1h`, `1h30m12s`, `1d`, `2d12h`. `0` means never for `ttl`.

## Sizes

`max_file_size` accepts a number of bytes (`52428800`) or a number with a unit: `B`, `KB`, `MB`, `GB` or `TB`, in any case, with an optional decimal part (`1.5GB`). Units are powers of 1024, so `1MB` is 1048576 bytes.

## Validation

hybrids3 checks the file at startup and exits with status 1 on the first problem, logging one JSON line that names it. Nothing is served until the file is valid. [Troubleshooting](troubleshooting.md#startup-errors) lists every message with its fix.

## Applying changes

hybrids3 reads the file only at startup. Restart the container after editing it. Removing a bucket from the file leaves its files and metadata in `/data`; see [What lives in /data](deployment.md#what-lives-in-data).
