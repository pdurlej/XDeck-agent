# XDeck-agent

> **Lab telescope, not a product.**  
> Reads / navigates **whatever is already visible** in an open Debug XDeck window.  
> **No** topic-search product · **no** unattended overnight agent · **no** post/reply/like tools.  
> Honest limits: see [docs in the Project store](https://github.com/pdurlej/XDeck-agent) / red-team notes (`xdeck-agent-redteam.md` in the companion Project). Prefer **official X API / X MCP** for search & writes.

Personal macOS fork of **[morishin/XDeck](https://github.com/morishin/XDeck)** with an **opt-in localhost agent bridge** so Cursor / Claude Code / Codex can inspect the same live WKWebView x.com session (no cookie export).

Upstream XDeck is an 𝕏 / TweetDeck-style multi-column macOS client. This repo keeps that app and adds Debug-only agent tooling.

> **Upstream:** https://github.com/morishin/XDeck — credit for the base app.  
> **This fork:** unofficial, personal, Debug-only. Not for App Store / Homebrew Release.

<img width="120" height="120" alt="XDeck icon" src="https://github.com/user-attachments/assets/b0076952-c7b4-4024-a337-8df37c05f88c" />

## What the agent bridge does

When Debug XDeck runs with `XDECK_AGENT=1`:

1. Listens on **`127.0.0.1:18765`** (loopback; bearer token required).
2. Holds column `WKWebView` refs and runs `evaluateJavaScript` / `load` / `reload`.
3. **Stable bearer token** (mode `0600`) — reused across app restarts when the file is still valid:
   - **`/Users/Shared/XDeck-agent/agent.token`** — canonical for CLI/MCP (Debug absolute-path entitlement)
   - Sandbox container App Support (internal) + best-effort `~/Library/Application Support/XDeck/agent.token`
   - **Never `/tmp`.** Prefer reading the file (or `XDECK_AGENT_TOKEN_FILE`); cached `XDECK_AGENT_TOKEN` env stays valid across restarts until you rotate with `XDECK_AGENT_ROTATE_TOKEN=1`.
4. HTTP + stdio **MCP** (`agent-bridge/`):

| Tool / route | Role |
|--------------|------|
| `health` / `list_columns` | Session + column metadata; `health` includes per-column `needs_human` / `challenge` |
| `read_column` | **Structured** tweet cards (`id`, `author`, `handle`, `text`, `time`, `url`) + `needs_human` on login/CAPTCHA/error shell. Raw `innerText` is **opt-in** (`include_text`); optional `limit` caps card count |
| `navigate_column` | SPA-safe navigate (pushState / search-box); waits for search tweets / retries error shells |
| `scroll_column` | Scroll timeline viewport |
| `reload_column` | Reload WebView |
| `eval_js` | **Opt-in only** (`XDECK_AGENT_EVAL=1` on MCP **and** the XDeck app). Absent from `tools/list` by default; HTTP `POST /eval` → **404** when unset. Powerful — can mutate the SPA |

`read_column` tweet cards may include `isAd`, `retweetedBy`, `quoted`, `media` when present. Status `url` is normalized (never `/analytics`).

`click` / `type` / `post_tweet` / … return **HTTP 501 Not Implemented** (honest — not “needs confirm”).

## Run Debug XDeck (Mac)

```sh
git clone https://github.com/pdurlej/XDeck-agent.git
cd XDeck-agent
# Debug is ad-hoc by default (no DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY=-):
xcodebuild -scheme XDeck -configuration Debug build
# Or open XDeck.xcodeproj — Scheme XDeck → Debug (shared scheme sets XDECK_AGENT=1)
# Keep bundle id me.morishin.XDeck to reuse WebKit login. Release still uses the project team.
```

Debug uses `XDeck/XDeck.Debug.entitlements` (`network.server` + home-relative App Support exception) and **ad-hoc** signing so `xcodebuild` works without a local cert. Release uses `XDeck/XDeck.entitlements` (**no** server) + team signing.

### curl smoke

```sh
TOKEN=$(cat /Users/Shared/XDeck-agent/agent.token 2>/dev/null \
  || cat "$HOME/Library/Application Support/XDeck/agent.token")
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18765/health
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18765/columns/0/text
curl -sS -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"column":1,"url":"https://x.com/search?q=openrig&src=typed_query"}' \
  http://127.0.0.1:18765/navigate
```

## MCP (Cursor · Claude Code · Codex)

```sh
cd agent-bridge && npm install
# entrypoint (use YOUR clone path):
node mcp-server.js
npm run smoke
```

### Cursor — `~/.cursor/mcp.json`

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

### Claude Code

```sh
claude mcp add -s user xdeck-agent -- \
  node /absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js
```

### Codex

```sh
codex mcp add xdeck-agent -- \
  node /absolute/path/to/XDeck-agent/agent-bridge/mcp-server.js
```

Optional env: `XDECK_AGENT_URL`, `XDECK_AGENT_TOKEN`, `XDECK_AGENT_TOKEN_FILE`.

## Remotes

```text
upstream  https://github.com/morishin/XDeck.git
origin    https://github.com/pdurlej/XDeck-agent.git
```

## License

Same as upstream XDeck — see [LICENSE](./LICENSE).
