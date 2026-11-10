---
title: "Behind a reverse proxy"
description: "Serve hybrids3 under a path prefix behind nginx without breaking AWS Signature V4, and get https presigned URLs with FORWARDED_ALLOW_IPS."
nav_order: 10
---

# Behind a reverse proxy

S3 signatures cover the request path and the `Host` header. Many proxies serve an app under a subpath such as `/storage/` by stripping the prefix, so the server sees `/bucket/key` while the client signed `/storage/bucket/key`, and every signature check fails. hybrids3 avoids that with the `path_prefix` setting: it serves every route under the prefix itself, so the proxy forwards the path unchanged and both sides agree on what was signed.

## Configuration

```yaml
path_prefix: /storage
```

With this set, every route moves under the prefix: `/storage/health`, `/storage/<bucket>/<key>`, `/storage/presign/...` and `/storage/mcp/`. A request outside the prefix gets an empty `404`.

## nginx

```nginx
location /storage {
    proxy_pass http://hybrids3:8080;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 0;
}
```

Two details break signatures when they are wrong:

- `proxy_pass` has no trailing slash. `proxy_pass http://hybrids3:8080/;` has a URI part, and nginx then replaces the matched location with it, which strips `/storage`.
- `Host` is `$http_host`, not `$host`. `$host` drops the port, so a client that signed `Host: example.com:4000` would be checked against `Host: example.com`.

`client_max_body_size 0` turns off nginx's own 1 MB upload limit and leaves the size check to the bucket's `max_file_size`.

## Clients

```python
s3 = boto3.client(
    "s3",
    endpoint_url="https://example.com/storage",
    aws_access_key_id="uploads-id",
    aws_secret_access_key="uploads-secret",
    region_name="us-east-1",
    config=Config(signature_version="s3v4"),
)
```

```bash
curl https://example.com/storage/uploads/file.txt
```

```json
{
  "mcpServers": {
    "hybrids3": {
      "type": "streamable-http",
      "url": "https://example.com/storage/mcp/"
    }
  }
}
```

The MCP connection token check is skipped when `path_prefix` is set; see [MCP server](mcp.md#connection-token-optional).

## HTTPS and presigned URLs

`POST /presign/...` builds the URL from the scheme and host of the incoming request. TLS ends at the proxy, so hybrids3 sees `http` and returns `http://` URLs. uvicorn would take the scheme from `X-Forwarded-Proto`, but by default it only trusts that header from `127.0.0.1`. Tell it the proxy's address:

```bash
docker run -d --name hybrids3 \
  -e FORWARDED_ALLOW_IPS=172.18.0.10 \
  -v ./config.yaml:/config/config.yaml:ro \
  -v hybrids3-data:/data \
  psyb0t/hybrids3
```

`FORWARDED_ALLOW_IPS` takes a comma-separated list of addresses or networks. `*` trusts every client, which is only safe when nothing but the proxy can reach port 8080. The signature does not cover the scheme, so an `http://` URL that you rewrite to `https://` still works.

## Without a prefix

A proxy that gives hybrids3 its own host name, such as `storage.example.com`, needs no `path_prefix`. Keep `proxy_set_header Host $http_host` either way.

## Other proxies

The rule is the same for Caddy, Traefik or HAProxy: forward the path unchanged and keep the `Host` header the client sent. The test suite checks this nginx setup, without the body size line, in [`tests/test_proxy.sh`](https://github.com/psyb0t/docker-hybrids3/blob/main/tests/test_proxy.sh).
