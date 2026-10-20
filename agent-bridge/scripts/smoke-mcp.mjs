#!/usr/bin/env node
/**
 * Brief stdio MCP smoke: initialize → tools/list → tools/call health.
 * Uses newline-delimited JSON (current @modelcontextprotocol/sdk stdio framing).
 */
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.resolve(__dirname, "../mcp-server.js");
const node = process.execPath;

async function main() {
  const child = spawn(node, [serverPath], {
    stdio: ["pipe", "pipe", "pipe"],
    env: process.env,
    cwd: path.resolve(__dirname, ".."),
  });

  let stderr = "";
  child.stderr.on("data", (d) => {
    stderr += d.toString("utf8");
  });

  const rl = readline.createInterface({ input: child.stdout });
  const pending = new Map();
  let nextId = 1;

  rl.on("line", (line) => {
    if (!line.trim()) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (msg.id != null && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  });

  function request(method, params) {
    const id = nextId++;
    const msg = { jsonrpc: "2.0", id, method, params };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }, 15000);
      pending.set(id, (response) => {
        clearTimeout(timer);
        resolve(response);
      });
      child.stdin.write(`${JSON.stringify(msg)}\n`);
    });
  }

  function notify(method, params) {
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  try {
    const init = await request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "xdeck-smoke", version: "0.1.0" },
    });
    if (init.error) throw new Error(JSON.stringify(init.error));
    notify("notifications/initialized", {});

    const listed = await request("tools/list", {});
    if (listed.error) throw new Error(JSON.stringify(listed.error));
    const names = (listed.result?.tools || []).map((t) => t.name).sort();
    const expected = [
      "eval_js",
      "health",
      "list_columns",
      "navigate_column",
      "read_column",
      "reload_column",
      "scroll_column",
    ];
    for (const name of expected) {
      if (!names.includes(name)) {
        throw new Error(`missing tool ${name}; got ${names.join(", ")}`);
      }
    }

    const healthCall = await request("tools/call", {
      name: "health",
      arguments: {},
    });
    if (healthCall.error) throw new Error(JSON.stringify(healthCall.error));
    if (healthCall.result?.isError) {
      throw new Error(
        healthCall.result.content?.[0]?.text || "health tool error"
      );
    }
    const text = healthCall.result?.content?.[0]?.text || "";
    const parsed = JSON.parse(text);
    if (!parsed.ok) throw new Error(`health not ok: ${text}`);

    const readCall = await request("tools/call", {
      name: "read_column",
      arguments: { column: 0, include_text: false },
    });
    if (readCall.result?.isError) {
      throw new Error(readCall.result.content?.[0]?.text || "read_column error");
    }
    const readParsed = JSON.parse(readCall.result?.content?.[0]?.text || "{}");

    console.log(
      JSON.stringify(
        {
          ok: true,
          tools: names,
          health: {
            user: parsed.user,
            columnCount: parsed.columnCount,
            port: parsed.port,
          },
          read_column: {
            tweetCount: readParsed.tweetCount ?? readParsed.tweets?.length,
            sampleId: readParsed.tweets?.[0]?.id ?? null,
          },
        },
        null,
        2
      )
    );
  } finally {
    try {
      child.stdin.end();
    } catch {
      /* ignore */
    }
    child.kill("SIGTERM");
  }

  if (stderr.trim()) {
    console.error(stderr.trim());
  }
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
