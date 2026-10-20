# xdeck-agent-bridge

Stdio **MCP** + thin CLI for the opt-in XDeck localhost agent HTTP API (`127.0.0.1:18765`).

**Read-only tools:** `health`, `list_columns`, `read_column`, `eval_js`  
No cookie export. Write routes on the bridge return 400 until a later slice.

## Prerequisites

1. Run Debug XDeck with `XDECK_AGENT=1` (see repo root / `APPLY.md`).
2. Token at `~/Library/Application Support/XDeck/agent.token`.
3. Node **≥ 18** (`/opt/homebrew/bin/node` on Apple Silicon Homebrew).

## Install deps

```sh
cd /Users/pd/Developer/BuildScratch/XDeck-agent-bridge/agent-bridge
npm install
```

## Entrypoint (all clients)

```text
/opt/homebrew/bin/node /Users/pd/Developer/BuildScratch/XDeck-agent-bridge/agent-bridge/mcp-server.js
```

Equivalent: `npm run mcp` from this directory, or the bin name `xdeck-agent-mcp` after `npm link`.

## CLI

```sh
node cli.js health
node cli.js columns
node cli.js read 0
node cli.js eval 0 'document.title'
npm run smoke   # stdio MCP initialize + tools/list + health
```

## Cursor

Merge into `~/.cursor/mcp.json` (do not wipe other servers):

```json
{
  "mcpServers": {
    "xdeck-agent": {
      "command": "/opt/homebrew/bin/node",
      "args": [
        "/Users/pd/Developer/BuildScratch/XDeck-agent-bridge/agent-bridge/mcp-server.js"
      ]
    }
  }
}
```

Then: **Cursor Settings → MCP** → confirm `xdeck-agent` is enabled; reload window if needed.

## Claude Code

User scope (global):

```sh
claude mcp add -s user xdeck-agent -- \
  /opt/homebrew/bin/node \
  /Users/pd/Developer/BuildScratch/XDeck-agent-bridge/agent-bridge/mcp-server.js
```

Or `claude mcp add-json -s user xdeck-agent '{"type":"stdio","command":"/opt/homebrew/bin/node","args":["/Users/pd/Developer/BuildScratch/XDeck-agent-bridge/agent-bridge/mcp-server.js"]}'`

Check: `claude mcp get xdeck-agent` / `claude mcp list`

## Codex

```sh
codex mcp add xdeck-agent -- \
  /opt/homebrew/bin/node \
  /Users/pd/Developer/BuildScratch/XDeck-agent-bridge/agent-bridge/mcp-server.js
```

Writes `[mcp_servers.xdeck-agent]` into `~/.codex/config.toml`.  
Check: `codex mcp get xdeck-agent`

## Env (optional)

| Var | Default |
|-----|---------|
| `XDECK_AGENT_URL` | `http://127.0.0.1:18765` |
| `XDECK_AGENT_TOKEN` | (unset — read token file) |
| `XDECK_AGENT_TOKEN_FILE` | `~/Library/Application Support/XDeck/agent.token` |

## Security

- Loopback + bearer only.
- Tools annotated `readOnlyHint: true`.
- Keep Debug-only; never ship agent port on by default in Release/Homebrew.
