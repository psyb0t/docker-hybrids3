# Makefile — single entry point for all dev / build / test / lockfile ops.
#
# Rules of the road:
#   - Everything runs inside the dev container ($(DEV_RUN)) — never on the
#     host. The one exception is `test`, which calls `./test.sh` directly:
#     that script needs the host docker daemon to spawn the test container.
#   - Dep mutations (pkg-add / pkg-remove / pkg-update / pkg-upgrade) bump
#     the supply-chain age gate FIRST via scripts/bump_exclude_newer.sh,
#     then run uv inside the dev container. pkg-lock does not bump.
#   - Production Dockerfile installs from uv.lock with hash verification.
#     There is no `pip install` anywhere in this project.

# ── Image names ──────────────────────────────────────────────────────────────
IMAGE_NAME := psyb0t/hybrids3
TAG        := latest
TEST_TAG   := $(TAG)-test
DEV_IMAGE  := psyb0t/hybrids3-dev:latest

# ── Supply-chain ─────────────────────────────────────────────────────────────
PYPROJECT  := pyproject.toml
BUMP_HOST  := scripts/bump_exclude_newer.sh $(PYPROJECT)

# ── Sandboxed run ────────────────────────────────────────────────────────────
# Workspace at /work; runs as host UID/GID so file writes don't end up root.
# No docker socket — installs and tests run with zero blast radius on host.
UID := $(shell id -u)
GID := $(shell id -g)
DEV_RUN := docker run --rm \
	-u $(UID):$(GID) -e HOME=/tmp \
	-v $(PWD):/work -w /work \
	$(DEV_IMAGE)

.PHONY: help all dev-image shell \
	pkg-lock pkg-add pkg-remove pkg-update pkg-upgrade \
	lint format test-unit test \
	build run stop logs clean

all: help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── Dev container ────────────────────────────────────────────────────────────

dev-image: ## Build the sandboxed dev container (most other targets depend on this)
	docker build -f Dockerfile.dev -t $(DEV_IMAGE) .

shell: dev-image ## Open an interactive shell in the dev container
	docker run --rm -it \
		-u $(UID):$(GID) -e HOME=/tmp \
		-v $(PWD):/work -w /work \
		$(DEV_IMAGE) bash

# ── Lockfile / dependency mutations ──────────────────────────────────────────
# Every mutation bumps the supply-chain age gate to today-minus-3-days BEFORE
# uv runs, so the lockfile and the gate move forward atomically in a single
# commit. pkg-lock is the only target that does NOT bump (no mutation).

pkg-lock: dev-image ## Refresh uv.lock honoring current exclude-newer (no bump)
	$(DEV_RUN) uv lock

pkg-upgrade: dev-image ## Bump exclude-newer + upgrade ALL packages
	$(BUMP_HOST)
	$(DEV_RUN) uv lock --upgrade

pkg-add: dev-image ## Bump exclude-newer + add a package  (usage: make pkg-add PKG=name[==ver])
	@test -n "$(PKG)" || (echo "usage: make pkg-add PKG=name[==ver]" >&2; exit 1)
	$(BUMP_HOST)
	$(DEV_RUN) uv add --no-sync $(PKG)

pkg-remove: dev-image ## Bump exclude-newer + remove a package  (usage: make pkg-remove PKG=name)
	@test -n "$(PKG)" || (echo "usage: make pkg-remove PKG=name" >&2; exit 1)
	$(BUMP_HOST)
	$(DEV_RUN) uv remove --no-sync $(PKG)

pkg-update: dev-image ## Bump exclude-newer + upgrade ONE package  (usage: make pkg-update PKG=name)
	@test -n "$(PKG)" || (echo "usage: make pkg-update PKG=name" >&2; exit 1)
	$(BUMP_HOST)
	$(DEV_RUN) uv lock --upgrade-package $(PKG)

# ── Lint / format / unit tests ───────────────────────────────────────────────

lint: dev-image ## Run flake8 + mypy on the source tree
	$(DEV_RUN) flake8 app tests
	$(DEV_RUN) mypy app

format: dev-image ## Auto-format with autoflake + isort + black
	$(DEV_RUN) autoflake -r -i --remove-all-unused-imports --remove-unused-variables app tests
	$(DEV_RUN) isort app tests
	$(DEV_RUN) black app tests

test-unit: dev-image ## Run Python unit tests inside the dev container
	$(DEV_RUN) pytest tests/test_lock_unit.py -v

# ── Integration tests ────────────────────────────────────────────────────────
# Runs on the host: test.sh shells out to `docker build` / `docker run` against
# the host daemon. DIND would only add ceremony — see CLAUDE.md carve-out.
# Host needs: docker + curl + python3 with boto3 + fastmcp installed.

test: build test-unit ## Build prod image + run unit tests + run integration suite
	./test.sh

# ── Production image ─────────────────────────────────────────────────────────

build: ## Build the production image (uv sync --frozen, no pip anywhere)
	docker build -t $(IMAGE_NAME):$(TAG) .

run: ## Run the production container locally (needs ./config.yaml)
	docker run -d --name hybrids3 \
		-p 8080:8080 \
		-v $(PWD)/config.yaml:/config/config.yaml:ro \
		-v hybrids3-data:/data \
		$(IMAGE_NAME):$(TAG)

stop: ## Stop and remove the running container
	docker stop hybrids3 && docker rm hybrids3

logs: ## Tail container logs
	docker logs -f hybrids3

clean: ## Remove built images
	-docker rmi $(IMAGE_NAME):$(TAG)
	-docker rmi $(IMAGE_NAME):$(TEST_TAG)
	-docker rmi $(DEV_IMAGE)
