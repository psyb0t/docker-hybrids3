# Docker images and dependencies

- `Dockerfile` builds the production image in two stages: the builder installs only locked runtime dependencies with `uv sync --frozen --no-dev --no-install-project` into `/opt/venv`; the runtime stage copies that venv and `app/`, installs `libmagic1`, and runs as `hybrids3` (UID 1000) with `CMD ["python", "main.py"]`. There is no `pip install` anywhere; keep it that way.
- The Python base and `uv` are pinned by digest in both Dockerfiles, with the tag in a comment above. Bump them deliberately, both files together.
- Keep `LABEL io.modelcontextprotocol.server.name="io.github.psyb0t/hybrids3"`; the MCP Registry checks it against `name` in `server.json`.
- `Dockerfile.dev` bakes the full locked environment (runtime plus `dev` group) and runs `make lint`, `format`, `test-unit`, `shell`, the `pkg-*` targets and the Python helpers of the integration suite. Changing `pyproject.toml` or `uv.lock` rebuilds it.
- Dependency changes go only through `make pkg-add`, `pkg-remove`, `pkg-update` or `pkg-upgrade`. They move `[tool.uv] exclude-newer` to three days ago with `scripts/bump_exclude_newer.sh` before running `uv`, so the gate and the lockfile move in one commit. `make pkg-lock` relocks without moving the gate. Never run `uv` by hand and never edit `uv.lock`.
- Pin every dependency exactly (`name==x.y.z`) in `pyproject.toml`.
- `.dockerignore` keeps tests, docs, Markdown, local config, caches and Git metadata out of the build context. The production image needs only `pyproject.toml`, `uv.lock` and `app/`; anything else it needs must be added to the Dockerfile and removed from `.dockerignore`.
- The pipeline builds `linux/amd64` and `linux/arm64`. Do not add a dependency without wheels or a build path for both.
