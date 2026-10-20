#!/usr/bin/env node
import {
  listColumns,
  readColumn,
  evalJs,
  health,
  navigateColumn,
  scrollColumn,
  reloadColumn,
  tokenPath,
  DEFAULT_BASE,
} from "./lib/client.js";

function usage() {
  console.error(`xdeck-agent — CLI for XDeck localhost bridge (lab telescope)

Usage:
  xdeck-agent health
  xdeck-agent columns
  xdeck-agent read <columnIndex> [--no-text] [--max-chars N]
  xdeck-agent navigate <columnIndex> <url>
  xdeck-agent scroll <columnIndex> [deltaY]
  xdeck-agent reload <columnIndex>
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
        const includeText = !rest.includes("--no-text");
        console.log(
          JSON.stringify(
            await readColumn(index, { maxChars, includeText }),
            null,
            2
          )
        );
        break;
      }
      case "navigate": {
        const index = Number(rest[0]);
        const url = rest[1];
        if (!Number.isInteger(index) || !url) usage();
        console.log(JSON.stringify(await navigateColumn(index, url), null, 2));
        break;
      }
      case "scroll": {
        const index = Number(rest[0]);
        const delta = rest[1] !== undefined ? Number(rest[1]) : 800;
        if (!Number.isInteger(index)) usage();
        console.log(JSON.stringify(await scrollColumn(index, delta), null, 2));
        break;
      }
      case "reload": {
        const index = Number(rest[0]);
        if (!Number.isInteger(index)) usage();
        console.log(JSON.stringify(await reloadColumn(index), null, 2));
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
