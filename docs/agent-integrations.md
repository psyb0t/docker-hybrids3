---
title: "Agent integrations"
description: "Install the hybrids3 agent skill and plugins in Claude Code, Codex and OpenClaw, and use the stdio MCP bridge for clients without remote MCP support."
nav_order: 11
---

# Agent integrations

Besides the [MCP server](mcp.md) built into the container, the repository ships an agent skill and a small MCP bridge plugin. The skill teaches an agent the three APIs, the auth rules and when not to delete things. The plugin connects stdio-only MCP clients to a running server. Both talk to a hybrids3 instance you already run; neither starts one.

## The skill

The skill lives in [`.agents/skills/hybrids3/`](https://github.com/psyb0t/docker-hybrids3/tree/main/.agents/skills/hybrids3): the instructions in `SKILL.md`, a setup reference in `references/setup.md` and `scripts/hybrids3.sh`, a curl wrapper with `put`, `get`, `info`, `list`, `delete`, `buckets`, `presign` and `health` commands. Any agent that reads `.agents/skills/`, such as [peen](https://github.com/psyb0t/peen), picks it up from a checkout of this repository.

It reads these environment variables:

| Variable | Meaning |
| --- | --- |
| `HYBRIDS3_URL` | Server URL, including any `path_prefix`. `scripts/hybrids3.sh` defaults to `http://localhost:8080` |
| `HYBRIDS3_KEY` | A bucket key or the master key, sent as the Bearer token |
| `HYBRIDS3_PUBLIC_KEY` | The matching `public_key`, for S3 clients |
| `HYBRIDS3_MASTER_KEY`, `HYBRIDS3_MASTER_PUBLIC_KEY` | Master credentials, for cross-bucket work |

The skill tells agents never to delete or overwrite an object unless the user named that exact key, and never to change the server's configuration on their own.

## Claude Code

```bash
claude plugin marketplace add psyb0t/agents
claude plugin install hybrids3@psyb0t
```

Claude Code asks for the server URL and, when the endpoint uses a connection token, a bucket key or the master key. It stores the key in the system keychain. To add only the MCP server, without the skill:

```bash
claude mcp add --transport http hybrids3 http://localhost:8080/mcp/
```

## Codex

```bash
codex plugin marketplace add psyb0t/agents
codex plugin add hybrids3@psyb0t
```

Installed from the marketplace, the skill is invoked as `$hybrids3:hybrids3`. Codex also loads skills from `.agents/skills/` in the repository it works in, with no install, and there the skill is invoked as `$hybrids3`.

## OpenClaw

Every release publishes the skill to ClawHub:

```bash
openclaw skills install @psyb0t/hybrids3
```

For MCP clients that only run local stdio servers, the `@psyb0t/hybrids3` plugin in [`.agents/plugins/hybrids3/`](https://github.com/psyb0t/docker-hybrids3/tree/main/.agents/plugins/hybrids3) bridges stdio to the server's `/mcp/` endpoint through [`mcp-remote`](https://www.npmjs.com/package/mcp-remote):

```bash
openclaw plugins install clawhub:@psyb0t/hybrids3
```

Set `HYBRIDS3_URL` to the server URL; the bridge appends `/mcp/`. Set `HYBRIDS3_KEY` when the endpoint expects a connection token, and the bridge sends it as `Authorization: Bearer`. The tools still need their own `auth_key` argument. The plugin is MIT licensed, unlike the rest of the repository.

A client that supports remote Streamable HTTP servers does not need the bridge; point it at `$HYBRIDS3_URL/mcp/` directly.

## MCP Registry

The image is listed in the official MCP Registry as `io.github.psyb0t/hybrids3`, from [`server.json`](https://github.com/psyb0t/docker-hybrids3/blob/main/server.json). The registry entry points at `docker.io/psyb0t/hybrids3` with the Streamable HTTP transport at `http://localhost:8080/mcp/`.
