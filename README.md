# XDeck-agent

Personal macOS fork of **[morishin/XDeck](https://github.com/morishin/XDeck)** with an **opt-in localhost agent bridge** so Cursor / Claude Code / Codex can **read** the same live WKWebView x.com session (no official X API, no cookie export).

Upstream XDeck is an 𝕏 / TweetDeck-style multi-column macOS client (Safari UA, Ad-Blocking). This repo keeps that app and adds Debug-only agent tooling.

> **Upstream:** https://github.com/morishin/XDeck — all credit for the base app.  
> **This fork:** unofficial, personal, **read-only** agent slice. Not for App Store / Homebrew Release.

<img width="120" height="120" alt="XDeck icon" src="https://github.com/user-attachments/assets/b0076952-c7b4-4024-a337-8df37c05f88c" />

## What the agent bridge does

When Debug XDeck runs with `XDECK_AGENT=1`:

1. Listens on **`127.0.0.1:18765`** (loopback; bearer token required).
2. Holds a registry of column `WKWebView`s and runs `evaluateJavaScript` for agents.
3. Writes a token to `~/Library/Application Support/XDeck/agent.token` (mode `0600`).
4. Exposes read-only HTTP + a stdio **MCP** (`agent-bridge/`) with tools:
   - `health` · `list_columns` · `read_column` · `eval_js`

Write stubs (`click` / `post_tweet`, …) return **400** until a later confirm-gated slice.

## Run Debug XDeck (Mac)

```sh
git clone https://github.com/pdurlej/XDeck-agent.git
cd XDeck-agent
open XDeck.xcodeproj
# Scheme XDeck → Debug (shared scheme sets XDECK_AGENT=1)
# Sign with your Apple Development team; keep bundle id me.morishin.XDeck to reuse WebKit login container
```

Debug uses `XDeck/XDeck.Debug.entitlements` (`network.client` + **`network.server`** + token-mirror exceptions). Release still uses `XDeck/XDeck.entitlements` (**no** server).

Toolbar chip **Agent :18765** when the bridge is up. Log into x.com inside the app as usual.

### curl smoke

```sh
TOKEN="$HOME/Library/Application Support/XDeck/agent.token"
curl -sS -H "Authorization: Bearer $(cat "$TOKEN")" http://127.0.0.1:18765/health
curl -sS -H "Authorization: Bearer $(cat "$TOKEN")" http://127.0.0.1:18765/columns/0/text
```

## MCP (Cursor · Claude Code · Codex)

```sh
cd agent-bridge
npm install
# entrypoint:
#   node mcp-server.js
# or absolute:
#   /opt/homebrew/bin/node /absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js
npm run smoke   # initialize + tools/list + health
```

### Cursor — `~/.cursor/mcp.json`

```json
{
  "mcpServers": {
    "xdeck-agent": {
      "command": "/opt/homebrew/bin/node",
      "args": ["/absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js"]
    }
  }
}
```

Then Settings → MCP → enable **xdeck-agent** (reload window if needed).

### Claude Code

```sh
claude mcp add -s user xdeck-agent -- \
  /opt/homebrew/bin/node \
  /absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js
```

### Codex

```sh
codex mcp add xdeck-agent -- \
  /opt/homebrew/bin/node \
  /absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js
```

Optional env: `XDECK_AGENT_URL`, `XDECK_AGENT_TOKEN`, `XDECK_AGENT_TOKEN_FILE`.

## Upstream XDeck (base app)

Installation / column `settings.json` docs: see [morishin/XDeck](https://github.com/morishin/XDeck). Stock Homebrew/App Store builds **do not** include this agent bridge.

## Remotes

```text
upstream  https://github.com/morishin/XDeck.git
origin    https://github.com/pdurlej/XDeck-agent.git
```

## License

Same as upstream XDeck — see [LICENSE](./LICENSE).
