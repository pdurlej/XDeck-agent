#!/usr/bin/env node
import {
  listColumns,
  readColumn,
  evalJs,
  health,
  tokenPath,
  DEFAULT_BASE,
} from "./lib/client.js";

function usage() {
  console.error(`xdeck-agent — thin CLI for XDeck localhost bridge (read-only)

Usage:
  xdeck-agent health
  xdeck-agent columns
  xdeck-agent read <columnIndex> [--max-chars N]
  xdeck-agent eval <columnIndex> <js>

Env:
  XDECK_AGENT_URL          default ${DEFAULT_BASE}
  XDECK_AGENT_TOKEN        bearer token (else read token file)
  XDECK_AGENT_TOKEN_FILE   default ${tokenPath()}
`);
  process.exit(1);
}

async function main() {
  const [, , cmd, ...rest] = process.argv;
  if (!cmd || cmd === "-h" || cmd === "--help") usage();

  try {
    switch (cmd) {
      case "health": {
        console.log(JSON.stringify(await health(), null, 2));
        break;
      }
      case "columns":
      case "list": {
        console.log(JSON.stringify(await listColumns(), null, 2));
        break;
      }
      case "read": {
        const index = Number(rest[0]);
        if (!Number.isInteger(index)) usage();
        let maxChars;
        const maxIdx = rest.indexOf("--max-chars");
        if (maxIdx >= 0) maxChars = Number(rest[maxIdx + 1]);
        console.log(JSON.stringify(await readColumn(index, { maxChars }), null, 2));
        break;
      }
      case "eval": {
        const index = Number(rest[0]);
        const js = rest.slice(1).join(" ");
        if (!Number.isInteger(index) || !js) usage();
        console.log(JSON.stringify(await evalJs(index, js), null, 2));
        break;
      }
      default:
        usage();
    }
  } catch (err) {
    console.error(err.message || String(err));
    process.exit(1);
  }
}

main();
