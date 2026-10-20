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

Exit code `1` if any scenario is `fail`; `partial` still exits `0`.

## Env

Same as CLI/MCP: `XDECK_AGENT_URL`, `XDECK_AGENT_TOKEN`, `XDECK_AGENT_TOKEN_FILE`.  
Scenario 5 expects `XDECK_AGENT_EVAL` **unset** on the running XDeck app (and harness clears it for the MCP spawn).
