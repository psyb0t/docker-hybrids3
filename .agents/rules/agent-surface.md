# Agent surface

Applies to `.agents/skills/`, `.agents/plugins/`, `.agents/.claude-plugin/`, `.agents/.codex-plugin/`, `server.json` and `glama.json`.

- The skill (`.agents/skills/hybrids3/SKILL.md`, `references/setup.md`, `scripts/hybrids3.sh`) is a consumer of a server the user already runs. It must not tell an agent to edit `config.yaml`, change bucket visibility or expose ports unless the user asks.
- Keep the destructive-operation guardrails next to every `DELETE`, `delete_object` and presigned `PUT` in the skill.
- Every route, tool, argument, default and limit named in the skill must match the code and the docs site. Fix both when either changes.
- `scripts/hybrids3.sh` prints its own header comment (lines 2 to 30) as help text. Keep the usage block inside those lines when editing it.
- The OpenClaw plugin (`.agents/plugins/hybrids3/`) is MIT, unlike the WTFPL repository. Its `bin/cli.js` only proxies stdio through `mcp-remote` to `$HYBRIDS3_URL/mcp/`, with `Authorization: Bearer $HYBRIDS3_KEY` when that is set. Stdout is the MCP channel, so diagnostics go to stderr and the token is never logged.
- The tool list in the plugin README, `openclaw.plugin.json` and the skill must match the `@mcp.tool` functions in `app/mcp_server.py`.
- `pipeline.yml` publishes exactly the directories listed in `skill_names` and `plugin_names`. Add a new skill or plugin directory to those arrays.
- `server.json` and the Dockerfile `LABEL` share the name `io.github.psyb0t/hybrids3`. Keep them equal.
