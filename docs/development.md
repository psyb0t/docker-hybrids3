---
title: "Development"
description: "Work on hybrids3: the sandboxed dev container, make targets for lint and tests, the integration suite, dependency changes, CI and how releases are cut."
nav_order: 15
---

# Development

Everything runs in containers. The host needs Docker, Make, Bash, curl and Git; no Python, `pip` or `uv`. The [`Makefile`](https://github.com/psyb0t/docker-hybrids3/blob/main/Makefile) is the entry point, and `make help` lists every target.

## The dev container

[`Dockerfile.dev`](https://github.com/psyb0t/docker-hybrids3/blob/main/Dockerfile.dev) builds `psyb0t/hybrids3-dev:latest` with the full locked environment from `uv.lock`, runtime and dev dependencies together. Make targets run it with the repository mounted at `/work`, as your UID, with no Docker socket. It rebuilds when `pyproject.toml` or `uv.lock` change.

```bash
make dev-image   # build it (other targets do this for you)
make shell       # interactive shell inside it
```

## Lint and format

```bash
make lint     # flake8 app tests, then mypy app
make format   # autoflake, isort and black on app and tests
```

black, isort and flake8 use a line length of 100. black, isort and mypy read their settings from [`pyproject.toml`](https://github.com/psyb0t/docker-hybrids3/blob/main/pyproject.toml); flake8 reads [`.flake8`](https://github.com/psyb0t/docker-hybrids3/blob/main/.flake8).

## Tests

```bash
make test-unit   # pytest tests/test_lock_unit.py in the dev container
make test        # production image, unit tests, then the integration suite
```

`make test` is what CI runs. The integration suite, [`test.sh`](https://github.com/psyb0t/docker-hybrids3/blob/main/test.sh), builds `psyb0t/hybrids3:latest-test`, starts it with a test configuration, runs every test against it by container IP and removes it again. The proxy tests start an extra hybrids3 container with a `path_prefix` and an nginx container in front of it. Output also goes to `test.log`.

The tests are Bash functions in [`tests/`](https://github.com/psyb0t/docker-hybrids3/tree/main/tests), one file per area: HTTP, S3, MCP, auth, expiry, edge cases, concurrency, locks, proxy and security. Python snippets inside them (boto3, the FastMCP client, JSON parsing) run through a `py` helper. With `TEST_PYTHON_IMAGE` set, which `make test` does, the helper runs them in the dev image; without it, it uses the host's `python3`, which then needs `boto3` and `fastmcp`.

Run single tests after building the dev image:

```bash
make dev-image
./test.sh --help
TEST_PYTHON_IMAGE=psyb0t/hybrids3-dev:latest ./test.sh test_s3_presigned_private
```

A new test is a `test_*` function in a `tests/test_*.sh` file followed by `ALL_TESTS+=(test_name)`.

## Running a local build

```bash
cp config.example.yaml config.yaml   # then change the keys
make build
make run    # container "hybrids3" on port 8080
make logs
make stop
```

`config.yaml` is gitignored.

## Dependencies

[uv](https://docs.astral.sh/uv/) manages dependencies with a hash-locked `uv.lock` and a supply-chain age gate: `[tool.uv] exclude-newer` in `pyproject.toml` refuses any package version published after a fixed date. Every dependency change moves that date to three days ago in the same commit, through [`scripts/bump_exclude_newer.sh`](https://github.com/psyb0t/docker-hybrids3/blob/main/scripts/bump_exclude_newer.sh), then relocks.

| Target | What it does | Moves the gate? |
| --- | --- | --- |
| `make pkg-lock` | Relock under the current gate | No |
| `make pkg-add PKG=name==1.2.3` | Add a package | Yes |
| `make pkg-remove PKG=name` | Remove a package | Yes |
| `make pkg-update PKG=name` | Upgrade one package | Yes |
| `make pkg-upgrade` | Upgrade every package | Yes |

Do not run `uv` by hand. Every supported change has a target, so the gate and the lockfile always move together.

## Production image

`make build` builds `psyb0t/hybrids3:latest` from the multi-stage [`Dockerfile`](https://github.com/psyb0t/docker-hybrids3/blob/main/Dockerfile). The builder stage installs locked runtime dependencies with `uv sync --frozen --no-dev`; the runtime stage copies only that virtual environment and `app/` onto the same digest-pinned Python base, adds `libmagic1` and runs as UID 1000. There is no `pip install` anywhere.

## Documentation

The site you are reading is [`docs/`](https://github.com/psyb0t/docker-hybrids3/tree/main/docs), built by GitHub Pages with Jekyll and the Just the Docs theme. Build it locally with the same image GitHub uses:

```bash
make docs   # build the site into a gitignored output directory
```

## CI

[`.github/workflows/pipeline.yml`](https://github.com/psyb0t/docker-hybrids3/blob/main/.github/workflows/pipeline.yml) runs on every push, using the shared workflows in [psyb0t/reusable-github-workflows](https://github.com/psyb0t/reusable-github-workflows):

| Push | Jobs |
| --- | --- |
| Any branch | `code`: `make lint` and `make test` |
| `main` | `code`, then the image build for `linux/amd64` and `linux/arm64`, pushed as `latest` and `sha-<commit>` with a vulnerability scan, then the badges |
| `vX.Y.Z` tag | `wait` for the `main` run of the tagged commit to pass, `docker-promote` the `sha-<commit>` image to the release tag without rebuilding, `release` the GitHub release, then publish the skill and plugin to ClawHub and the entry to the MCP Registry |

The other workflows mirror the repository to GitLab and Codeberg, archive it, copy issues back from the mirrors and close pull requests.

## Releases

A release is an annotated `vX.Y.Z` tag on a `main` commit whose pipeline run passed. Write the CHANGELOG entry and update the version in `.agents/.codex-plugin/plugin.json` in the commit before tagging. The tag pipeline promotes that commit's image, so what was tested on `main` is what ships.
