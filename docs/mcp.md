---
title: "MCP server"
description: "Connect AI agents to hybrids3 over MCP Streamable HTTP at /mcp/: client setup, connection and per-tool auth, and every tool with its arguments and results."
nav_order: 7
---

# MCP server

hybrids3 runs a [Model Context Protocol](https://modelcontextprotocol.io/) server at `/mcp/` on the same port as everything else, using the Streamable HTTP transport. An agent gets seven typed tools for uploading, downloading, listing and deleting objects and for creating presigned URLs. The tools are defined in [`app/mcp_server.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/mcp_server.py) with [FastMCP](https://gofastmcp.com/).

## Connecting

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

With Claude Code:

```bash
claude mcp add --transport http hybrids3 http://localhost:8080/mcp/
```

Behind a `path_prefix`, the endpoint moves with it, for example `https://example.com/storage/mcp/`. For clients that only run local stdio servers, the [OpenClaw plugin](agent-integrations.md#openclaw) bridges stdio to this endpoint.

## Authentication

There are two layers, and only the second one decides what a tool may do.

### Connection token (optional)

A client may send a token with every MCP request, either as a header or, for clients that cannot set headers, as a query parameter:

```text
Authorization: Bearer <master-key-or-bucket-key>
```

```text
http://localhost:8080/mcp/?auth=<master-key-or-bucket-key>
```

A token that matches neither the master key nor any bucket key gets `401` before the request reaches the MCP server. A request without a token passes. A valid token does not grant or limit anything inside the tools: a bucket key here does not restrict the connection to that bucket.

When `path_prefix` is set, this check does not run, because the middleware looks for paths that start with `/mcp` before the prefix is removed. A wrong token then passes through like no token. Tool calls are still checked by their `auth_key`.

### Per-tool `auth_key`

Every tool that touches a bucket takes an `auth_key` argument: the bucket's private `key` or the master key. Reads on a public bucket (`download_object`, `list_objects`, `object_info`) accept an empty `auth_key`. Uploads, deletes, presigning and anything on a private bucket require it.

```text
download_object(bucket="uploads", key="file.txt")
upload_object(bucket="uploads", key="file.txt", content="hello", auth_key="uploads-secret")
download_object(bucket="permanent", key="doc.pdf", auth_key="perm-secret")
list_buckets(auth_key="your-master-key")
```

A wrong or missing `auth_key` gets `{"error": "Bucket '<name>' does not exist"}`, the same as a bucket that does not exist.

## Tools

Every tool returns a JSON object. Success includes `"ok": true`; failure is `{"error": "<message>"}`. Clients that support structured output get it as `structuredContent`, with a text copy for the rest. Unexpected exceptions are masked, so a caller never sees a stack trace.

### upload_object

Writes an object, replacing any object with the same key.

| Argument | Default | Meaning |
| --- | --- | --- |
| `bucket` | required | Bucket name |
| `key` | required | Object key, `/` allowed |
| `content` | required | Text, or base64 when `encoding` is `base64` |
| `auth_key` | required | Bucket key or master key |
| `content_type` | `""` | MIME type. Empty means [detect it](storage.md#mime-type-detection) |
| `encoding` | `"utf-8"` | `utf-8` for text, `base64` for binary |

Returns `ok`, `size`, `etag` (MD5) and `content_type`. The bucket's `max_file_size` applies to the decoded bytes. The whole object travels inside one JSON-RPC message, so use the HTTP or S3 API for large files.

### download_object

| Argument | Default | Meaning |
| --- | --- | --- |
| `bucket` | required | Bucket name |
| `key` | required | Object key |
| `auth_key` | `""` | Needed for private buckets |
| `encoding` | `"utf-8"` | `utf-8` returns text, `base64` returns base64 |

Returns `ok`, `content`, `encoding`, `content_type`, `size` and `etag`. When `encoding` is `utf-8` and the bytes are not valid UTF-8, the content comes back as base64 and `encoding` says `base64`. Objects over 50 MB are refused with an error that points to `GET /<bucket>/<key>` over HTTP.

### delete_object

| Argument | Default | Meaning |
| --- | --- | --- |
| `bucket` | required | Bucket name |
| `key` | required | Object key |
| `auth_key` | required | Bucket key or master key |

Returns `{"ok": true}`, also when the object did not exist. Deletion cannot be undone.

### list_objects

| Argument | Default | Meaning |
| --- | --- | --- |
| `bucket` | required | Bucket name |
| `auth_key` | `""` | Needed for private buckets |
| `prefix` | `""` | Only keys that start with this text |
| `max_keys` | `100` | Clamped to 1 to 1000 |

Returns `ok`, `bucket`, `count` and `objects`, a list of `{"key", "size", "content_type"}` sorted by key.

### list_buckets

| Argument | Default | Meaning |
| --- | --- | --- |
| `auth_key` | required | The master key lists every bucket, a bucket key lists its own |

Returns `ok` and `buckets`, each with `name`, `public`, `ttl_seconds` and `max_file_size_bytes`. Keys are never included. A key that matches nothing gets `{"error": "Access denied"}`.

### object_info

| Argument | Default | Meaning |
| --- | --- | --- |
| `bucket` | required | Bucket name |
| `key` | required | Object key |
| `auth_key` | `""` | Needed for private buckets |

Returns `ok`, `key`, `content_type`, `size`, `etag`, `uploaded_at` and `expires_at` (`null` without a TTL), without the content.

### presign_url

| Argument | Default | Meaning |
| --- | --- | --- |
| `bucket` | required | Bucket name |
| `key` | required | Object key |
| `auth_key` | required | Bucket key or master key |
| `method` | `"GET"` | `GET` or `PUT` |
| `expires` | `3600` | Seconds, clamped to 1 to 604800 (7 days) |
| `base_url` | `""` | The URL clients use to reach the server, with any path prefix, such as `https://example.com/storage` |
| `host` | `""` | The `Host` header the URL will be used with. Empty takes it from `base_url` |

Returns `ok`, `url`, `method` and `expires`. The MCP server does not know its public address, so always pass `base_url`; without it the URL has no scheme or host. A signed URL only works when it is requested with the same host it was signed for. [Presigned URLs](presigned-urls.md) explains the rules, which are the same as for the HTTP endpoint.

## Calling it without a client

The server keeps a session per client. Start one with `initialize`, take the `mcp-session-id` response header, confirm with `notifications/initialized`, then send tool calls with that header. Every request needs an `Accept` header that lists both JSON and server-sent events, and the URL needs its trailing slash; `/mcp` without it is answered by the bucket routes.

```bash
MCP=http://localhost:8080/mcp/

SID=$(
  curl -s -D - -o /dev/null "$MCP" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}' |
    awk -F': ' 'tolower($1) == "mcp-session-id" { print $2 }' |
    tr -d '\r'
)

curl -s "$MCP" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

```bash
curl -s "$MCP" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SID" \
  --data @- <<'EOF'
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "upload_object",
    "arguments": {
      "bucket": "uploads",
      "key": "note.txt",
      "content": "hello",
      "auth_key": "uploads-secret"
    }
  }
}
EOF
```

The answer arrives as a server-sent event whose `data:` line holds the JSON-RPC result. A request without a session ID gets `400` with `Bad Request: Missing session ID`.
