# xdeck-agent-bridge

Stdio **MCP** + CLI for the opt-in XDeck localhost agent HTTP API (`127.0.0.1:18765`).

**Lab telescope:** structured read + navigate/scroll/reload of an **open** Debug XDeck window.  
**Not** a topic-search product, unattended poller, or poster.  
`eval_js` is **opt-in** (`XDECK_AGENT_EVAL=1`) — powerful, not registered by default.

## Prerequisites

1. Build/run this fork with `XDECK_AGENT=1` (Debug scheme).
2. Stable token (reused across restarts) at `/Users/Shared/XDeck-agent/agent.token` or `~/Library/Application Support/XDeck/agent.token`. Never `/tmp`. Re-read the file after rotate (`XDECK_AGENT_ROTATE_TOKEN=1`).
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
| `health` | Bridge up? Includes aggregate + per-column `needs_human` / `challenge` |
| `list_columns` | Column metadata |
| `read_column` | Tweet cards + optional raw text (`include_text` default **false**); optional `limit`; `needs_human` on login/CAPTCHA/error shell |
| `navigate_column` | Load URL in column |
| `scroll_column` | Scroll timeline |
| `reload_column` | Reload WebView |
| `acquire_column` | Lease a free **agent-only** hidden column (indices 100+, `type=agent`, `visible=false`) |
| `release_column` | Release an agent column lease by `agent_id` / column |
| `eval_js` | **Opt-in** (`XDECK_AGENT_EVAL=1`); arbitrary JS — **can mutate**; HTTP `/eval` returns **404** when unset |

**Protecting the human deck:** `navigate_column` / `scroll_column` on user columns (0–n) return **403** unless `XDECK_AGENT_ALLOW_USER_NAV=1`. Prefer `acquire_column` → navigate/scroll with matching `agent_id`. Agent columns share the same WebKit cookie jar; they stay attached (near-invisible) so `document.visibilityState` remains `visible`. Min navigation interval per agent column: `XDECK_AGENT_NAV_MIN_INTERVAL_MS` (default 5000).

## CLI

```sh
node cli.js health
node cli.js read 0
node cli.js navigate 0 'https://x.com/search?q=test&src=typed_query'
node cli.js scroll 0 800
node cli.js reload 0
npm run smoke
npm run evals
```

Live scenario suite (feed / topic / poll / write-honesty): see [`evals/README.md`](./evals/README.md).

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
| `XDECK_AGENT_TOKEN` | (unset — read token file; file is stable across restarts unless rotated) |
| `XDECK_AGENT_TOKEN_FILE` | overrides default search order (`/Users/Shared/XDeck-agent/agent.token`, then App Support) |
| `XDECK_AGENT_ROTATE_TOKEN` | set on the **XDeck app** process to mint a new token on next bridge start |
| `XDECK_AGENT_EVAL` | set `1` on **MCP** (to register `eval_js`) **and** the **XDeck app** (to enable `POST /eval`). Default unset → tool absent + HTTP **404** |
