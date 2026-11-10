# Python style

Applies to `app/` and `tests/test_lock_unit.py`.

- Target Python 3.12 only (`requires-python = ">=3.12,<3.13"` in `pyproject.toml`). Both Dockerfiles use the same digest-pinned `python:3.12-slim-bookworm` base.
- Modules in `app/` import each other by bare name (`from config import AppConfig`). The image runs `python main.py` from `/app`, so a package-style `from app.config import` breaks at runtime.
- `make lint` runs `flake8 app tests` and `mypy app` in the dev container and must pass with zero findings. Line length is 100 for black, isort (`pyproject.toml`) and flake8 (`.flake8`). Run `make format` before committing.
- Type every function signature in new code. Module globals that `main.py` wires at startup (`routes.config`, `routes.db_conn`, `mcp_server._config` and the rest) are declared with their real type and `# type: ignore[assignment]`; follow that pattern instead of `Optional` checks on every use.
- Log through `logger.get_logger(__name__)`. Pass context in `extra={...}`, never by formatting it into the message, so it lands as JSON fields. Never log a bucket key, the master key or a full presigned URL.
- Compare credentials only with `hmac.compare_digest`.
- New limits get a module-level constant with a comment, as `MCP_MAX_DOWNLOAD_BYTES`, `ACQUIRE_TIMEOUT` and `_SIZE_UNITS` do, instead of a bare number in a handler.
- Invalid configuration logs one error naming the field and value, then exits with `sys.exit(1)` from `config.py`. Do not let a bad config start a half-working server.
