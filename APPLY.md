# Apply XDeck agent bridge sources (Mac)

Overlay these paths onto a checkout of [morishin/XDeck](https://github.com/morishin/XDeck) (or your fork). Paths below are relative to the XDeck **repo root**.

**Not live-tested** in cloud — smoke on Mac after Debug build with `XDECK_AGENT=1`.

## Exact file list

### New (copy as-is)

| Destination |
|-------------|
| `XDeck/Agent/ColumnRegistry.swift` |
| `XDeck/Agent/AgentBridge.swift` |
| `XDeck/Agent/AgentDOM.swift` |
| `XDeck/XDeck.Debug.entitlements` |
| `agent-bridge/package.json` |
| `agent-bridge/package-lock.json` |
| `agent-bridge/README.md` |
| `agent-bridge/cli.js` |
| `agent-bridge/mcp-server.js` |
| `agent-bridge/lib/client.js` |

### Replace (overwrite upstream)

| Destination |
|-------------|
| `XDeck/View/WebView.swift` |
| `XDeck/View/ContentView.swift` |
| `XDeck/XDeckApp.swift` |
| `XDeck.xcodeproj/project.pbxproj` |
| `XDeck.xcodeproj/xcshareddata/xcschemes/XDeck.xcscheme` |
| `README.md` (optional — agent section + sandbox notes) |

Create directory `XDeck/Agent/` if missing. After copying, open `XDeck.xcodeproj` in Xcode; Debug already uses `XDeck.Debug.entitlements` and scheme env `XDECK_AGENT=1`.

### From tarball

```sh
cd /path/to/XDeck
tar -xzf /path/to/xdeck-bridge-sources.tar.gz
# tarball root contains APPLY.md + the paths above; merge carefully:
# cp -R from extracted tree into repo root for the listed paths only
```

Or unpack and copy selectively:

```sh
tar -xzf xdeck-bridge-sources.tar.gz -C /tmp
cp -R /tmp/xdeck-bridge-sources/XDeck/Agent /path/to/XDeck/XDeck/
cp /tmp/xdeck-bridge-sources/XDeck/XDeck.Debug.entitlements /path/to/XDeck/XDeck/
cp /tmp/xdeck-bridge-sources/XDeck/View/WebView.swift /path/to/XDeck/XDeck/View/
cp /tmp/xdeck-bridge-sources/XDeck/View/ContentView.swift /path/to/XDeck/XDeck/View/
cp /tmp/xdeck-bridge-sources/XDeck/XDeckApp.swift /path/to/XDeck/XDeck/
cp /tmp/xdeck-bridge-sources/XDeck.xcodeproj/project.pbxproj /path/to/XDeck/XDeck.xcodeproj/
cp /tmp/xdeck-bridge-sources/XDeck.xcodeproj/xcshareddata/xcschemes/XDeck.xcscheme \
  /path/to/XDeck/XDeck.xcodeproj/xcshareddata/xcschemes/
cp -R /tmp/xdeck-bridge-sources/agent-bridge /path/to/XDeck/
# optional:
cp /tmp/xdeck-bridge-sources/README.md /path/to/XDeck/
```

## Build & run

1. Xcode → scheme **XDeck** → **Debug**
2. Confirm Run env: `XDECK_AGENT=1`
3. Build & run; log into x.com
4. Toolbar should show **Agent :18765**
5. Token: `~/Library/Application Support/XDeck/agent.token`

If bind fails under sandbox: confirm Debug `CODE_SIGN_ENTITLEMENTS` = `XDeck/XDeck.Debug.entitlements` (includes `network.server`), or temporarily disable App Sandbox for local Debug only. Do not change Release entitlements.

## Mac smoke curls

```sh
TOKEN="$HOME/Library/Application Support/XDeck/agent.token"

curl -sS -H "Authorization: Bearer $(cat "$TOKEN")" \
  http://127.0.0.1:18765/health

curl -sS -H "Authorization: Bearer $(cat "$TOKEN")" \
  http://127.0.0.1:18765/columns

curl -sS -H "Authorization: Bearer $(cat "$TOKEN")" \
  http://127.0.0.1:18765/columns/0/text

curl -sS -H "Authorization: Bearer $(cat "$TOKEN")" \
  -H 'Content-Type: application/json' \
  -d '{"column":0,"js":"document.title"}' \
  http://127.0.0.1:18765/eval
```

## MCP / CLI

```sh
cd agent-bridge && npm install
node cli.js health
node cli.js read 0
# Cursor MCP: command node, args [absolute path to mcp-server.js]
```

Design context: Project `docs/xdeck-wkwebview-agent-bridge.md` and `docs/xdeck-bridge-prototype-status.md`.
