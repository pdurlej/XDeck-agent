# XDeck scenario evals

Live pass/partial/fail suite against the Debug XDeck agent bridge (`127.0.0.1:18765`).

## Prerequisites

1. Debug XDeck from this repo running with `XDECK_AGENT=1` (bridge listening).
2. Token at `/Users/Shared/XDeck-agent/agent.token` or `~/Library/Application Support/XDeck/agent.token`.
3. Node ≥ 18 (`npm install` in `agent-bridge/` if needed).

## Run

```sh
cd agent-bridge
node evals/scenarios.mjs
node evals/scenarios.mjs --query cursor --column 0 --polls 3 --json /tmp/xdeck-scenario-evals.json
```

Or: `npm run evals`

## Scenarios

| # | Name | Pass criteria |
|---|------|---------------|
| 1 | Feed browse | `health` ok; structured `read_column` tweets ≥1 **or** honest empty array; `needs_human=false` on healthy home |
| 2 | Topic search | `navigate_column` to `https://x.com/search?q=…&f=live`; ready; tweets ≥1 **or** documented SPA/`errorShell` fail |
| 3 | Periodic poll | 2–3 `read_column` cycles (+ optional scroll/reload); stable/comparable ids; no crash |
| 4 | Write honesty | `POST /post_tweet`, `/reply`, `/retweet` → **HTTP 501** (never actually posts) |
| 5 | Eval gate | MCP `tools/list` omits `eval_js` by default; `POST /eval` + `/columns/0/eval` → **HTTP 404** when `XDECK_AGENT_EVAL` unset |
| 6 | read_column opts | Default response omits raw `text`; `limit=2` truncates cards; `includeText` opt-in works |
| 11 | Bind listener | Exactly one TCP listener on `18765` and it is `127.0.0.1` |
| 12 | Bind restart | **Opt-in** (`XDECK_EVAL_ALLOW_BRIDGE_KILL=1`): kill + relaunch private DerivedData app; unauth `/health` → **401** within 15s. Relaunch uses **only** `XDECK_AGENT=1` — never `XDECK_AGENT_EVAL`. |
| 13 | Eval remains gated | End-of-suite: wait for `hasWebView:true`, then `POST /eval` → **404** whose body contains **`Eval disabled`**. Column-not-found 404 must retry/fail — never pass. |
| 15 | Agent hidden columns | `/health` lists `type=agent` `visible:false` (indices ≥100, `visibilityState=visible`); two acquires → different columns; navigate column 0 → **403** |

Focused suite (search + scroll + lease expiry + column-0 unchanged):

```sh
npm run evals:agent-columns -- --query openrig
```

Navigate/scroll **must** `acquire_column` (no user-column fallback). A **403** on navigate grades **fail** — never pass on stale column-0 content. Scenario 1 / 6 / 7 are read-only on the user deck.

Exit code `1` if any scenario is `fail`; `partial` still exits `0`.

## Env

Same as CLI/MCP: `XDECK_AGENT_URL`, `XDECK_AGENT_TOKEN`, `XDECK_AGENT_TOKEN_FILE`.  
Scenario 5 + 13 expect `XDECK_AGENT_EVAL` **unset** on the running XDeck app (and harness clears it for the MCP spawn).

**Do not** kill a shared live `:18765` bridge during reviews. For TIME_WAIT restart tests, use a private DerivedData build and set `XDECK_EVAL_ALLOW_BRIDGE_KILL=1`. Without that flag, scenario 12 is skipped (`partial`).
