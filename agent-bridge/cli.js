#!/usr/bin/env node
import {
  listColumns,
  readColumn,
  evalJs,
  health,
  navigateColumn,
  scrollColumn,
  reloadColumn,
  acquireColumn,
  releaseColumn,
  tokenPath,
  DEFAULT_BASE,
} from "./lib/client.js";

function usage() {
  console.error(`xdeck-agent — CLI for XDeck localhost bridge (lab telescope)

Usage:
  xdeck-agent health
  xdeck-agent columns
  xdeck-agent read <columnIndex> [--text] [--limit N] [--max-chars N]
  xdeck-agent acquire <agentId> [--ttl seconds]
  xdeck-agent release [--agent <agentId>] [--column N]
  xdeck-agent navigate <columnIndex> <url> [--agent <agentId>]
  xdeck-agent scroll <columnIndex> [deltaY] [--agent <agentId>]
  xdeck-agent reload <columnIndex>
  xdeck-agent eval <columnIndex> <js>

Env:
  XDECK_AGENT_URL          default ${DEFAULT_BASE}
  XDECK_AGENT_TOKEN        bearer token (else read token file)
  XDECK_AGENT_TOKEN_FILE   default ${tokenPath()}
`);
  process.exit(1);
}

function takeFlag(rest, name) {
  const idx = rest.indexOf(name);
  if (idx < 0) return undefined;
  const value = rest[idx + 1];
  rest.splice(idx, 2);
  return value;
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
        let limit;
        const maxIdx = rest.indexOf("--max-chars");
        if (maxIdx >= 0) maxChars = Number(rest[maxIdx + 1]);
        const limitIdx = rest.indexOf("--limit");
        if (limitIdx >= 0) limit = Number(rest[limitIdx + 1]);
        // Raw text is opt-in; --no-text kept as a no-op alias for older scripts.
        const includeText = rest.includes("--text");
        console.log(
          JSON.stringify(
            await readColumn(index, { maxChars, includeText, limit }),
            null,
            2
          )
        );
        break;
      }
      case "acquire": {
        const agentId = rest[0];
        if (!agentId) usage();
        const ttlRaw = takeFlag(rest, "--ttl");
        const ttl = ttlRaw !== undefined ? Number(ttlRaw) : undefined;
        console.log(
          JSON.stringify(await acquireColumn(agentId, { ttl }), null, 2)
        );
        break;
      }
      case "release": {
        const agentId = takeFlag(rest, "--agent") || rest[0];
        const columnRaw = takeFlag(rest, "--column");
        const column =
          columnRaw !== undefined ? Number(columnRaw) : undefined;
        console.log(
          JSON.stringify(
            await releaseColumn({
              agentId,
              column: Number.isInteger(column) ? column : undefined,
            }),
            null,
            2
          )
        );
        break;
      }
      case "navigate": {
        const args = [...rest];
        const agentId = takeFlag(args, "--agent");
        const index = Number(args[0]);
        const url = args[1];
        if (!Number.isInteger(index) || !url) usage();
        console.log(
          JSON.stringify(
            await navigateColumn(index, url, { agentId }),
            null,
            2
          )
        );
        break;
      }
      case "scroll": {
        const args = [...rest];
        const agentId = takeFlag(args, "--agent");
        const index = Number(args[0]);
        const delta = args[1] !== undefined ? Number(args[1]) : 800;
        if (!Number.isInteger(index)) usage();
        console.log(
          JSON.stringify(
            await scrollColumn(index, delta, { agentId }),
            null,
            2
          )
        );
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
