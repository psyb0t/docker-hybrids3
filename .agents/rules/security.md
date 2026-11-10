# Security

- Never read, print or commit a real `config.yaml`. It holds the master key and bucket keys and is gitignored. Examples use the placeholder keys from `config.example.yaml` (`uploads-secret`, `perm-secret`, `change-me-to-something-secret`) or `your-master-key`; `.gitleaks.toml` allowlists only those exact Bearer placeholders.
- Private keys never leave the server: not in a response, a presigned URL (only `public_key` appears in `X-Amz-Credential`), a log line or an MCP result. `list_buckets` over MCP returns name, visibility, TTL and size limit only.
- An empty `master_key` disables the master key. Keep the `config.master_key and ...` guard on every master check.
- Hide bucket existence from unauthorized callers (`404 NoSuchBucket`). `GET /{bucket}?location` answers before the auth check today, which reveals whether a bucket exists; do not add more routes like it.
- Header-signed SigV4 requests are not checked for clock skew, and the `x-amz-content-sha256` value is not compared with the body. Presigned URLs are checked against their own `X-Amz-Expires`, and one without it never expires. `docs/security.md` says so; update it if any of this changes, and tell users to run behind TLS.
- Bound every external input: `max-keys` and MCP `max_keys` (1 to 1000), presign `expires` (1 to 604800), upload size (`max_file_size`), MCP download size (`MCP_MAX_DOWNLOAD_BYTES`), lock waiters (`lock_max_waiters`).
- The container runs as UID 1000 (`hybrids3`) and writes only `/data`. Do not add a root process or another writable path.
- Examples in docs and the skill bind the port to `127.0.0.1` or put the service behind a reverse proxy, and warn that `public: true` buckets are world-readable.
