# Changelog

All notable changes to this project are documented in this file.

## [v0.3.2] - 2026-07-26

### Changed

- Hardened the skill docs with explicit destructive-operation guardrails and public-bucket/network-exposure warnings — no behavior change.
  - `docker-compose` example now binds `127.0.0.1:8080:8080` (loopback-only) instead of publishing the port on all interfaces, matching the `docker run` example; added guidance to use an internal network + reverse proxy for real deployments.
  - Added a "Security & safety" section to the skill covering: public-bucket world-readability, loopback-vs-all-interfaces port binding, destructive/irreversible delete operations (`DELETE`, MCP `delete_object`, overwrite-via-`PUT`), and credential handling for bucket/master keys and presigned URLs.
  - Added inline agent guardrails next to each destructive operation (HTTP `DELETE`, S3 `delete_object`, MCP `delete_object`) instructing agents to never call them without explicit user intent and to never enumerate-then-bulk-delete.
