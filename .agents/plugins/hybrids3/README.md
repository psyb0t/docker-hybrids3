# @psyb0t/hybrids3

An OpenClaw/MCP plugin that connects your agent to a self-hosted
[hybrids3](https://github.com/psyb0t/docker-hybrids3) object storage service
over the [Model Context Protocol](https://modelcontextprotocol.io).

hybrids3 already serves a Streamable-HTTP MCP endpoint at `/mcp/`. This
package is a thin stdio↔HTTP bridge (via
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote)) for MCP clients that
speak local stdio servers — it forwards everything to your running hybrids3
instance and authenticates with your bearer token when the endpoint requires one.

> hybrids3 is **self-hosted**. This plugin does not ship the storage engine —
> it connects to a hybrids3 server that **you** run. See the
> [hybrids3 repo](https://github.com/psyb0t/docker-hybrids3) to stand one up.

## Tools

The hybrids3 MCP tools become available to your agent: `upload_object`,
`download_object`, `delete_object`, `list_objects`, `list_buckets`,
`object_info`, and `presign_url` — put/get/list/delete files and generate
presigned GET/PUT URLs against configured buckets.

## Configuration

| Env var | Required | Description |
|---|---|---|
| `HYBRIDS3_URL` | yes | Base URL of your running hybrids3 server, e.g. `http://localhost:8080`. The bridge appends `/mcp/`. |
| `HYBRIDS3_KEY` | no | Bearer token — a bucket's private key or the master key, only if the hybrids3 endpoint requires connection-level auth. |

## Install

Install it into your OpenClaw agent from ClawHub:

```bash
openclaw plugins install clawhub:@psyb0t/hybrids3
```

Then set `HYBRIDS3_URL` (and `HYBRIDS3_KEY` if your endpoint uses auth) in
the plugin's environment.

## Native remote MCP (no install)

If your MCP client already supports **remote** Streamable-HTTP servers, you
don't need this bridge — point the client straight at
`$HYBRIDS3_URL/mcp/` with an `Authorization: Bearer <token>` header.

## License

MIT. See [LICENSE](LICENSE).
