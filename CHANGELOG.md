# Changelog

All notable changes to this project are documented in this file.

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
