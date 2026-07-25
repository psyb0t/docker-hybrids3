#!/usr/bin/env node
// hybrids3 MCP bridge. A thin stdio<->HTTP proxy: forwards MCP over stdio to a
// running hybrids3 server's Streamable-HTTP endpoint (`$HYBRIDS3_URL/mcp/`),
// authenticating with `$HYBRIDS3_KEY` when the server requires it.
//
// stdout IS the MCP protocol channel, so diagnostics go to stderr only — the
// sole output here is a fatal pre-launch console.error (user-facing CLI
// output). The token is passed to the proxy as an argv header, never logged.
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const MCP_PATH = "/mcp/";

const base = process.env.HYBRIDS3_URL;

if (!base) {
  console.error(
    `[hybrids3-mcp] Missing HYBRIDS3_URL.

Point this bridge at your running hybrids3 server, e.g.:
  export HYBRIDS3_URL=http://localhost:8080

hybrids3 is self-hosted — see https://github.com/psyb0t/docker-hybrids3`,
  );
  process.exit(1);
}

const url = `${base.replace(/\/+$/, "")}${MCP_PATH}`;
const token = process.env.HYBRIDS3_KEY;
const proxyEntry = require.resolve("mcp-remote/dist/proxy.js");

const args = [proxyEntry, url, "--transport", "http-only"];
if (token) {
  args.push("--header", `Authorization: Bearer ${token}`);
}
args.push(...process.argv.slice(2));

const result = spawnSync(process.execPath, args, { stdio: "inherit" });
process.exit(result.status ?? 1);
