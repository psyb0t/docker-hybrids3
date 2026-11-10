# Interfaces: HTTP, S3 and MCP

Applies to `app/routes.py`, `app/mcp_server.py`, `app/auth.py`, `app/sigv4.py` and `app/s3xml.py`.

- One store, three front doors. An object written through any interface must be readable through the other two with the same metadata (`content_type`, `size`, `etag`, `uploaded_at`, `expires_at`).
- Auth rules are the same everywhere: public buckets allow anonymous reads (GET, HEAD, list), every write needs the bucket key or the master key, private buckets need a key for everything, presigning needs a key. HTTP enforces them in `_check_read_auth` and `_check_write_auth`; each MCP tool repeats them. A change to one side changes the other in the same commit, with tests on both.
- Unauthorized access to a bucket returns `404 NoSuchBucket` over HTTP and `{"error": "Bucket '<name>' does not exist"}` over MCP. Only `GET /` (403 `AccessDenied`) and a bad presigned GET URL (403 `AccessDenied`) differ; a bad presigned PUT URL gets the usual 404.
- `_is_s3` decides the response format: a `AWS4-HMAC-SHA256` Authorization header or any `x-amz-*` header gets S3 XML from `s3xml.py`, everything else gets JSON with `error`, `message` and `request_id`. New routes use `_err` so both formats stay right.
- SigV4 verification reads the signed path from `_effective_path`. Presigned URL generation takes the `path_prefix` part separately and signs `prefix + /bucket/key`. Keep both in step with `PathPrefixMiddleware`.
- Presigned URLs: only `GET` and `PUT` (`_PRESIGN_METHODS` and the MCP check). `GET` on a public bucket returns a plain URL with `expires: null`; everything else is signed with an expiry clamped to 1 to 604800 seconds. A presigned `PUT` is always signed.
- Every new or changed route, query parameter, status code, error code or MCP tool argument updates `docs/http-api.md`, `docs/s3-api.md` or `docs/mcp.md`, the skill (`.agents/skills/hybrids3/SKILL.md`) and the plugin descriptions that list tool names.
- MCP tools return plain dicts. Success carries `"ok": True`; failure carries `"error"` with a message safe to show a caller. Never return a stack trace or a filesystem path.
