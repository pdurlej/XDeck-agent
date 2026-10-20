# XDeck-agent

**XDeck-agent:** a local, read-only sidekick for your X deck. It glances and scrolls now and then, so you catch the posts worth your time without living in the feed. Your tweet FOMO, handled.

Fork of **[morishin/XDeck](https://github.com/morishin/XDeck)** under MIT. Unaffiliated with X / Twitter.

### Principles

- **Mac-only** — loopback `127.0.0.1`, no cloud service
- **Read-only** — no posting, liking, replying, or clicking through the bridge
- **Drafts are suggestions** — you post yourself in the open X UI
- **Human pacing** — glance and scroll now and then, not a firehose
- **`eval_js` off by default** — opt-in only when you explicitly enable it

Upstream XDeck is an 𝕏 / TweetDeck-style multi-column macOS client. This repo keeps that app and adds Debug-only agent tooling (localhost bridge + MCP) so Cursor / Claude Code / Codex can inspect the same live WKWebView x.com session — no cookie export.

> Prefer the **official X API / X MCP** if you need search products or writes.

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
| `read_column` | **Structured** tweet cards (`id`, `author`, `handle`, `text`, `time`, `url`, optional `metrics` / `article` / `inReplyTo` / `isPinned` / `isAd` / …) + `needs_human` on login/CAPTCHA/error shell. On `/notifications` also returns typed `notifications[]`. Raw `innerText` is **opt-in** (`include_text`); optional `limit` caps card count |
| `navigate_column` | SPA-safe navigate (pushState / search-box); waits for search **and status** tweets / retries error shells; logs when navigate > ~10s |
| `scroll_column` | Scroll timeline viewport |
| `reload_column` | Reload WebView |
| `eval_js` | **Opt-in only** (`XDECK_AGENT_EVAL=1` on MCP **and** the XDeck app). Absent from `tools/list` by default; HTTP `POST /eval` → **404** when unset. Powerful — can mutate the SPA |

`read_column` tweet cards may include `isAd`, `retweetedBy`, `quoted`, `media`, `metrics` (`replies`/`reposts`/`likes`/`views`/`bookmarks`), `article` (`title`/`preview`), `inReplyTo`, `isPinned` when present. Status `url` is normalized (never `/analytics`). Notifications columns add `notifications: [{type, actors, actorCount, target?, time?}]`.

`click` / `type` / `post_tweet` / … return **HTTP 501 Not Implemented** (honest — not “needs confirm”).

## Run Debug XDeck (Mac)

```sh
git clone https://github.com/pdurlej/XDeck-agent.git
cd XDeck-agent
# Debug is ad-hoc by default (CODE_SIGN_IDENTITY=-, empty DEVELOPMENT_TEAM):
# plain xcodebuild — no Apple Development cert required.
xcodebuild -scheme XDeck -configuration Debug \
  -derivedDataPath "$PWD/.derivedData" build
# Launch the *DerivedData product* (not a copy under /tmp):
open -n --env XDECK_AGENT=1 \
  "$PWD/.derivedData/Build/Products/Debug/XDeck.app"
# Or Xcode → Scheme XDeck → Debug (shared scheme sets XDECK_AGENT=1).
# Keep bundle id me.morishin.XDeck to reuse WebKit login.
```

**Launch protocol**

1. Prefer **`open` on the DerivedData product** — not `/tmp/XDeck-*.app`. Copies under `/tmp` plus LaunchAgent/`LSOpen` can hit sandbox_extension / error **-54** (“Nie można otworzyć XDeck”) even when ad-hoc signing is fine.
2. **Never overwrite** notarized `/Applications/XDeck.app` with an ad-hoc Debug build.
3. When **swapping builds**: start the new app → verify `GET /health` → only then stop the old process. On failure, keep/restore the old bridge (do not kill first).
4. Optional with a personal team:  
   `xcodebuild … CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<yourTeam> CODE_SIGN_IDENTITY=`  
   (clears forced `-`). Hardened runtime then applies for real; with ad-hoc, Xcode may strip the runtime flag at codesign time — that is OK.

Debug uses `XDeck/XDeck.Debug.entitlements` (`network.server` + App Support / `/Users/Shared/XDeck-agent` exceptions), **ad-hoc** signing, `ENABLE_HARDENED_RUNTIME=YES`, and `ENABLE_DEBUG_DYLIB=NO`. Release uses `XDeck/XDeck.entitlements` (**no** server) + team signing.

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

Point Claude Code / Cursor / Codex at **your clone** on `main` (or the PR branch under test). Replace `path-to-your-clone` below with that checkout path.

Entrypoint: `path-to-your-clone/agent-bridge/mcp-server.js`  
Fast-forward when stale (must not stay on old tips that still expose `eval_js` by default):

```sh
cd path-to-your-clone
git fetch origin && git checkout main && git pull --ff-only origin main
cd agent-bridge && npm install && npm run smoke
```

```sh
cd agent-bridge && npm install
node mcp-server.js
npm run smoke
```

### Cursor — `~/.cursor/mcp.json`

```json
{
  "mcpServers": {
    "xdeck-agent": {
      "command": "/opt/homebrew/bin/node",
      "args": [
        "path-to-your-clone/agent-bridge/mcp-server.js"
      ]
    }
  }
}
```

### Claude Code

```sh
claude mcp add -s user xdeck-agent -- \
  /opt/homebrew/bin/node \
  path-to-your-clone/agent-bridge/mcp-server.js
```

### Codex

```sh
codex mcp add xdeck-agent -- \
  /opt/homebrew/bin/node \
  path-to-your-clone/agent-bridge/mcp-server.js
```

Optional env: `XDECK_AGENT_URL`, `XDECK_AGENT_TOKEN`, `XDECK_AGENT_TOKEN_FILE`.

## Remotes

```text
upstream  https://github.com/morishin/XDeck.git
origin    https://github.com/pdurlej/XDeck-agent.git
```

## License

Same as upstream XDeck — see [LICENSE](./LICENSE).
