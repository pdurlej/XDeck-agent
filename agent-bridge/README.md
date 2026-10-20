# xdeck-agent-bridge

Stdio **MCP** + CLI for the opt-in XDeck localhost agent HTTP API (`127.0.0.1:18765`).

**Lab telescope:** structured read + navigate/scroll/reload of an **open** Debug XDeck window.  
**Not** a topic-search product, unattended poller, or poster. `eval_js` is powerful (not read-only).

## Prerequisites

1. Build/run this fork with `XDECK_AGENT=1` (Debug scheme).
2. Token at `/Users/Shared/XDeck-agent/agent.token` (or `~/Library/Application Support/XDeck/agent.token`).
3. Node ≥ 18.

## Install

```sh
cd agent-bridge
npm install
```

## Entrypoint

From this directory:

```sh
node mcp-server.js
```

Or with an absolute path to **your** clone:

```sh
node /absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js
```

## Tools

| Tool | Notes |
|------|--------|
| `health` | Bridge up? |
| `list_columns` | Column metadata |
| `read_column` | Tweet cards + optional raw text |
| `navigate_column` | Load URL in column |
| `scroll_column` | Scroll timeline |
| `reload_column` | Reload WebView |
| `eval_js` | Arbitrary JS — **can mutate**; not annotated read-only |

## CLI

```sh
node cli.js health
node cli.js read 0
node cli.js navigate 0 'https://x.com/search?q=test&src=typed_query'
node cli.js scroll 0 800
node cli.js reload 0
npm run smoke
```

## Client snippets

Replace `/absolute/path/to/XDeck-agent` with your checkout.

**Cursor** `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "xdeck-agent": {
      "command": "node",
      "args": ["/absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js"]
    }
  }
}
```

**Claude Code:**

```sh
claude mcp add -s user xdeck-agent -- \
  node /absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js
```

**Codex:**

```sh
codex mcp add xdeck-agent -- \
  node /absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js
```

## Env

| Var | Default |
|-----|---------|
| `XDECK_AGENT_URL` | `http://127.0.0.1:18765` |
| `XDECK_AGENT_TOKEN` | (unset — read token file) |
| `XDECK_AGENT_TOKEN_FILE` | overrides default search order (`/Users/Shared/XDeck-agent/agent.token`, then App Support) |
