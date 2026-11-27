# Changelog

All notable changes to this project are documented in this file.

## [v0.3.12], 2026-11-27

- The agent skill now covers only using a hybrids3 server that is already running: the S3 API, the plain HTTP API, the MCP tools and the `scripts/hybrids3.sh` helper. Install and deployment steps are out of the skill and stay in the [documentation](https://psyb0t.github.io/docker-hybrids3/). `references/setup.md` is removed.
- The ClawHub publish job no longer sets `pin_images` or `pin_source_urls`, so publishing no longer rewrites the skill's image reference or links to the release.
- The agent-surface and security rules now say the skill covers use of the running server, links the docs for setup and carries no deployment examples.

## [v0.3.11], 2026-11-27

- The agent skill now says where data goes and what cannot be undone. Requests go only to the host in `HYBRIDS3_URL`, which receives the keys and the object bytes, so anything beyond localhost should use `https://` through a TLS proxy. It describes deletes and overwrites as irreversible and limits them to the key the user named. Its frontmatter declares the network, shell and filesystem use.
- `scripts/hybrids3.sh info` exits 1 and prints the response headers to stderr when the server answers with a non-2xx status. It used to exit 0 on a 404.
- The copy of the skill published to ClawHub names the exact release image by digest, and its raw GitHub links to `main` point at the release tag. The repository files keep `latest` and `main`.
- The setup reference fetches `config.example.yaml` from `main`, because the `master` link did not exist, and shows the reverse proxy terminating TLS.
- The documentation site is built with Docusaurus instead of Jekyll, at the same page addresses. `make docs` builds it in a pinned Node container and fails on a broken link or anchor, `make docs-lock` refreshes its lockfile, and a docs workflow publishes it to GitHub Pages.
- A tag's image promotion no longer repeats the vulnerability scan or the Docker Hub description update that the `main` run already did, and the image job states its Docker Hub visibility and description settings.
- The rules in `.agents/rules/` keep only conventions specific to this repository.

## [v0.3.10], 2026-11-10

- The documentation is published at https://psyb0t.github.io/docker-hybrids3/. The configuration, HTTP, S3 and MCP API, keys and access, presigned URL, storage, deployment, reverse proxy, security, troubleshooting and development reference moved there from the README.
- Every branch push now runs lint, the unit tests and the integration suite before anything is built. A push to `main` publishes `:latest` and `:sha-<commit>`, and a release tag promotes that same image instead of rebuilding it, then cuts the GitHub release and publishes the skill, the plugin and the MCP Registry entry.
- `make test` runs the integration suite's Python helpers in the dev image, so the host needs only Docker, curl and Bash.
- Buy Me a Coffee is in the funding links, and `AGENTS.md` plus project rules in `.agents/rules/` are committed for coding agents.

## [v0.3.9], 2026-10-10

Documentation only. The README's agent integrations section names [peen](https://github.com/psyb0t/peen) as an example of an agent that reads `.agents/skills/`.

## [v0.3.8] - 2026-08-01

CI plumbing only. No code in this repo changed — every commit in this release touches `.github/workflows/`.

- The pipeline was split: building and publishing stay in `pipeline.yml`, and everything that leaves the host now lives beside it in `mirror-and-archive.yml`.
- The repo is mirrored to Codeberg as well as GitLab.
- It is archived to the Wayback Machine, Software Heritage and archive.org.
- Issues opened on either mirror are copied back to GitHub every six hours, and closed here when the original closes.
- Pull requests are switched off on the mirrors — they are force-pushed from GitHub, so anything merged there would be destroyed by the next sync. Issues and forking stay enabled.

## [v0.3.7] - 2026-07-27

- Fixed the Codex subsection of "## Agent integrations" — it told the reader to run `codex plugin marketplace add psyb0t/agents` and then stopped, never giving the actual install command. Added `codex plugin add hybrids3@psyb0t`.
- Corrected the invocation prose: a skill installed via the marketplace invokes as `$hybrids3:hybrids3`, while a skill Codex picks up automatically from a repo's own `.agents/skills/` (no install needed) invokes as plain `$hybrids3`. These are two different mechanisms and were previously conflated.

## [v0.3.6] - 2026-07-27

- Added `.agents/.claude-plugin/plugin.json` and `.agents/.codex-plugin/plugin.json` manifests so the existing skill and OpenClaw MCP-bridge plugin install natively in Claude Code and Codex.
- Added an "## Agent integrations" README section with copy-pasteable install commands for Claude Code, Codex, and OpenClaw (skill + MCP-bridge plugin).

## [v0.3.5] - 2026-07-27

- Added a GitHub Actions CI status badge to the README.

## [v0.3.4] - 2026-07-27

- Added self-hosted version and license badges plus a Docker Hub pulls badge; wired a badges job into pipeline.yml.

## [v0.3.3] - 2026-07-26

Listed on the official MCP Registry — no behavior change.

- Added `server.json` — published to the official Model Context Protocol Registry (`registry.modelcontextprotocol.io`) as `io.github.psyb0t/hybrids3`, pointing at the `psyb0t/hybrids3` Docker image. Ownership is proven by an `io.modelcontextprotocol.server.name` LABEL on the image; publishing runs on tag pushes via GitHub OIDC (secretless). Also added a `glama.json` maintainer claim.

## [v0.3.2] - 2026-07-26

### Changed

- Hardened the skill docs with explicit destructive-operation guardrails and public-bucket/network-exposure warnings — no behavior change.
  - `docker-compose` example now binds `127.0.0.1:8080:8080` (loopback-only) instead of publishing the port on all interfaces, matching the `docker run` example; added guidance to use an internal network + reverse proxy for real deployments.
  - Added a "Security & safety" section to the skill covering: public-bucket world-readability, loopback-vs-all-interfaces port binding, destructive/irreversible delete operations (`DELETE`, MCP `delete_object`, overwrite-via-`PUT`), and credential handling for bucket/master keys and presigned URLs.
  - Added inline agent guardrails next to each destructive operation (HTTP `DELETE`, S3 `delete_object`, MCP `delete_object`) instructing agents to never call them without explicit user intent and to never enumerate-then-bulk-delete.
