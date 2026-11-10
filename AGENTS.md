# hybrids3

Instructions for coding agents (Codex, Claude Code and others) and for people changing this repository. Users of the image want the documentation site, https://psyb0t.github.io/docker-hybrids3/, not this file.

## Agent setup

`CLAUDE.md` is a committed symlink to `AGENTS.md`, and `.claude` is a committed symlink to `.agents`, so Claude Code reads the same instructions, rules and skills as Codex. Claude's Edit and Write tools refuse to write through a symlink, so edit `AGENTS.md` and `.agents/rules/*.md` directly.

## What it is

One Docker image, `psyb0t/hybrids3`, that runs a small object storage server on port 8080. The same process answers the S3 API (AWS Signature V4, boto3 compatible), a plain HTTP API with Bearer tokens, and an MCP server over Streamable HTTP at `/mcp/`. Object metadata lives in SQLite at `/data/hybrids3.db`, object bytes are flat files under `/data/<bucket>/`. Buckets, keys and limits come only from `/config/config.yaml`; there is no API that creates or deletes a bucket. The repository also ships an agent skill, an OpenClaw stdio bridge plugin and the Claude Code and Codex plugin manifests.

## Architecture

All application code is in `app/`, flat modules imported by bare name (`from config import ...`), because the image copies `app/` to `/app` and runs `python main.py` there.

- `main.py`: builds the FastAPI app, runs the lifespan (load config, create bucket directories, open SQLite, build the `LockManager`, wire `routes` and `mcp_server` module globals, start the cleanup task), mounts the FastMCP app at `/mcp` and adds three middlewares. Starlette runs the last added first, so the order on a request is `RequestIdMiddleware` (request ID, `X-Request-Id`, `nosniff`), then `McpAuthMiddleware` (optional connection token for `/mcp`), then `PathPrefixMiddleware` (strips `path_prefix` for routing and keeps the original path in `scope["_original_path"]` for SigV4).
- `config.py`: `load_config` parses the YAML into `AppConfig` and `BucketConfig`. Every invalid value logs an error and calls `sys.exit(1)`. `DATA_DIR` is fixed at `/data`.
- `routes.py`: every HTTP and S3 route on one `APIRouter`. `_is_s3` (a `AWS4-HMAC-SHA256` Authorization header or any `x-amz-*` header) picks XML or JSON responses. `_check_read_auth` and `_check_write_auth` return `404 NoSuchBucket` to unauthorized callers so bucket existence does not leak.
- `auth.py`: Bearer token checks against the bucket key or master key with `hmac.compare_digest`, and SigV4 header or presigned URL checks that look the bucket up by `public_key`.
- `sigv4.py`: SigV4 parsing, verification and presigned URL generation. Verification uses `_effective_path`, the path the client signed, including `path_prefix`.
- `mcp_server.py`: the FastMCP server and its seven tools. Each tool takes an `auth_key` and repeats the HTTP auth rules itself; `mask_error_details=True` hides exceptions.
- `lock.py`: `LockManager`, an async read-write lock per `(bucket, key)` with acquire timeout, hold timeout and a waiter cap. Raises `LockTimeout`, `LockHoldTimeout` or `LockOverloaded`, which callers turn into `503`.
- `storage.py`: `_safe_path` (resolve plus `relative_to` against the bucket root), writes, reads, deletes with empty parent pruning, and the on-disk listing used by orphan cleanup.
- `db.py`: the `objects` table (`bucket`, `key`, `content_type`, `size`, `etag`, `uploaded_at`, `expires_at`), WAL mode, escaped `LIKE` prefix queries.
- `scheduler.py`: `cleanup_loop` sleeps `cleanup_interval`, then deletes expired objects and files that have no metadata row.
- `mimetype.py`: libmagic on the first 8 KB, extension fallback when libmagic says `text/plain` or `application/octet-stream`.
- `s3xml.py`: S3 XML for bucket lists, object lists, bucket location and errors.
- `logger.py`: one JSON object per line on stdout with a per-request `rid` from a context variable.

Request path for an upload: client -> `RequestIdMiddleware` -> `McpAuthMiddleware` -> `PathPrefixMiddleware` -> `routes.put_object` -> auth check -> `LockManager.write` -> stream the body to `<dest>.tmp.<hex>` with the size check -> rename -> MD5 ETag -> MIME detection -> `upsert_object`.

## Stack

- Python 3.12 (`requires-python = ">=3.12,<3.13"`), FastAPI, uvicorn, FastMCP 3, PyYAML, pytimeparse2, python-magic (with `libmagic1` from apt). Exact pins in `pyproject.toml`, hashes in `uv.lock`.
- `uv` with a supply-chain age gate: `[tool.uv] exclude-newer` in `pyproject.toml`, moved only by `scripts/bump_exclude_newer.sh` through the `pkg-*` Make targets.
- Images: `Dockerfile` (multi-stage production image, `uv sync --frozen --no-dev`, runs as UID 1000) and `Dockerfile.dev` (the dev container that lint, format, unit tests, dependency changes and the test helpers run in). Both pin the Python base and `uv` by digest.
- Dev tools in the `dev` dependency group: pytest, pytest-asyncio, boto3, flake8, black, isort, autoflake, mypy, vulture.
- Tests: pytest for `app/lock.py`, plus a Bash integration suite (`test.sh`, `tests/*.sh`) against a real container.
- CI: `.github/workflows/pipeline.yml` calling `psyb0t/reusable-github-workflows`.

## Layout

| Path | What it holds |
| --- | --- |
| `app/` | The application (see Architecture) |
| `Dockerfile` | Production image |
| `Dockerfile.dev` | Dev container with the full locked environment, used by `make lint`, `make test-unit` and the test helpers |
| `pyproject.toml`, `uv.lock` | Dependencies, age gate, black, isort and mypy settings |
| `.flake8` | flake8 settings (flake8 does not read `pyproject.toml`) |
| `config.example.yaml` | Annotated example configuration |
| `config.yaml` | Local configuration for `make run`, gitignored |
| `scripts/bump_exclude_newer.sh` | Moves the `exclude-newer` gate, called by the `pkg-*` targets |
| `test.sh`, `tests/common.sh` | Integration runner and its shared helpers |
| `tests/test_*.sh` | Integration tests, each registered in `ALL_TESTS` |
| `tests/test_lock_unit.py` | pytest unit tests for `app/lock.py` |
| `docs/` | The documentation site (GitHub Pages, Jekyll, Just the Docs) |
| `.agents/skills/hybrids3/` | The agent skill, its `references/setup.md` and the `scripts/hybrids3.sh` curl helper |
| `.agents/plugins/hybrids3/` | The OpenClaw stdio-to-HTTP MCP bridge plugin (MIT) |
| `.agents/.claude-plugin/`, `.agents/.codex-plugin/` | Claude Code and Codex plugin manifests |
| `.agents/rules/` | Rules for changing this repository |
| `server.json`, `glama.json` | MCP Registry and Glama metadata |
| `.gitleaks.toml` | Secret scan settings and the allowlisted placeholder keys |
| `.github/workflows/` | `pipeline.yml` plus repository housekeeping workflows |

## Commands

Docker, Make, Bash and curl are enough. Lint, unit tests and the Python test helpers run in the dev container.

```bash
make help        # every target
make lint        # flake8 + mypy in the dev container
make format      # autoflake + isort + black in the dev container
make test-unit   # pytest tests/test_lock_unit.py in the dev container
make test        # production image + unit tests + integration suite (what CI runs)
make build       # production image psyb0t/hybrids3:latest
make run         # run it locally with ./config.yaml, then make logs / make stop
make docs        # build the docs site with the GitHub Pages image
make pkg-add PKG=name==1.2.3   # dependency changes go through pkg-* targets only
```

Run one integration test with `TEST_PYTHON_IMAGE=psyb0t/hybrids3-dev:latest ./test.sh <test_name>` after `make dev-image`. `./test.sh --help` lists the test names.

## Project-specific landmines

- Buckets are configuration. Do not add an endpoint or tool that creates, deletes or reconfigures a bucket; `PUT /{bucket}` stays a no-op for boto3.
- The HTTP routes and the MCP tools implement the same auth rules separately (`routes._check_read_auth`/`_check_write_auth` and the checks at the top of each tool). Change both together.
- Unauthorized bucket access answers `404 NoSuchBucket`, not `401` or `403`. Keep that, so callers cannot tell a hidden bucket from a missing one.
- SigV4 verification must use `_effective_path`, never `request.url.path`, or every request behind `path_prefix` fails.
- Temporary upload files are named `<dest>.tmp.<hex>` and orphan cleanup skips any file whose name contains `.tmp.`. Keep the two in step.
- `_run_cleanup` and the write paths have no `await` between the rename and `upsert_object`, so the cleanup loop cannot delete a file between those two steps. Do not add one there.
- `make test` builds its own `psyb0t/hybrids3:latest-test` image and binds nothing to host ports; tests reach containers by bridge IP. The Python helpers reach them from a second container on the same bridge.

## Rules

Rules for every change live in `.agents/rules/`, one file per topic. Read the ones that match what you are touching before editing.
