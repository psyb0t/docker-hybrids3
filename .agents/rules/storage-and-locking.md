# Storage, metadata and locking

Applies to `app/storage.py`, `app/db.py`, `app/lock.py`, `app/scheduler.py`, `app/mimetype.py` and the write paths in `app/routes.py` and `app/mcp_server.py`.

- Every disk path for an object goes through `storage._safe_path`. It resolves the path and rejects anything outside `/data/<bucket>` with `ValueError`, which handlers turn into `400 InvalidKey` or `{"error": "Invalid object key"}`.
- Writes are atomic: write `<dest>.tmp.<8 hex>`, rename onto `dest`, then hash and `upsert_object`. If the metadata write fails, delete the file. HTTP uploads stream the body and stop at `max_file_size` with `413 EntityTooLarge`; MCP uploads check the decoded size before writing.
- `list_bucket_files` skips names containing `.tmp.`, so orphan cleanup never deletes an upload in progress. A change to the temporary name changes that filter too.
- Deleting a file prunes empty parent directories up to the bucket root. Deleting a missing object is not an error (`204` over HTTP, `ok` over MCP).
- Every object operation takes the per-key lock from `LockManager`: `read` for GET, HEAD and MCP downloads, `write` for PUT, DELETE and MCP uploads and deletes. Catch `LockTimeout`, `LockHoldTimeout` and `LockOverloaded` and answer `503` (HTTP) or an `error` dict (MCP). `object_info` and listings read SQLite without the lock.
- `LockManager` drops idle per-key locks after release. Keep `_drop_if_idle` in the `finally` blocks, or the lock table grows with every key ever touched.
- SQLite runs in WAL mode with one shared connection (`check_same_thread=False`). All database calls are synchronous and run on the event loop thread; do not move them to a thread pool without adding locking.
- The schema is created with `CREATE TABLE IF NOT EXISTS`. A schema change needs a migration that works on an existing `/data/hybrids3.db`, and a CHANGELOG note.
- TTL: `expires_at = uploaded_at + ttl` on every write, `NULL` when `ttl` is 0. Overwriting resets it. Timestamps are UTC ISO 8601 strings and compared as strings, so keep the format.
- MIME type: a client `Content-Type` wins unless it is empty, `application/octet-stream` or `application/x-www-form-urlencoded`; then `mimetype.detect` sniffs the first 8 KB. Keep `_GENERIC_CONTENT_TYPES` and the docs in step.
