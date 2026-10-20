#!/usr/bin/env node
/**
 * Stdio MCP server for XDeck AgentBridge (read-only).
 *
 * Speaks standard MCP JSON-RPC over stdin/stdout — suitable for Cursor,
 * Claude Code, and Codex. Never write logs to stdout (use stderr).
 *
 * Requires Debug XDeck running with XDECK_AGENT=1 on 127.0.0.1:18765.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { listColumns, readColumn, evalJs, health } from "./lib/client.js";

const READ_ONLY = {
  readOnlyHint: true,
  destructiveHint: false,
  openWorldHint: false,
};

function jsonResult(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
  };
}

function errorResult(err) {
  const message = err?.message || String(err);
  return {
    content: [{ type: "text", text: message }],
    isError: true,
  };
}

const server = new McpServer(
  { name: "xdeck-agent", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.registerTool(
  "health",
  {
    title: "XDeck bridge health",
    description:
      "Check whether the local XDeck agent bridge is up (127.0.0.1:18765) and report user handle + column count. Requires Debug XDeck with XDECK_AGENT=1.",
    inputSchema: {},
    annotations: READ_ONLY,
  },
  async () => {
    try {
      return jsonResult(await health());
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "list_columns",
  {
    title: "List XDeck columns",
    description:
      "List live XDeck columns (index, type, url, loading, hasWebView) from the same WKWebView session.",
    inputSchema: {},
    annotations: READ_ONLY,
  },
  async () => {
    try {
      return jsonResult(await listColumns());
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "read_column",
  {
    title: "Read XDeck column text",
    description:
      "Read visible document.body.innerText from an XDeck column WebView (logged-in x.com session). Optional max_chars truncates the returned text.",
    inputSchema: {
      column: z
        .number()
        .int()
        .min(0)
        .describe("Column index (0-based)"),
      max_chars: z
        .number()
        .int()
        .positive()
        .optional()
        .describe("Optional truncate length for returned text"),
    },
    annotations: READ_ONLY,
  },
  async ({ column, max_chars }) => {
    try {
      return jsonResult(await readColumn(column, { maxChars: max_chars }));
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "eval_js",
  {
    title: "Eval JS in XDeck column",
    description:
      "Evaluate JavaScript in a column WKWebView and return a JSON-serializable result. Read-focused escape hatch — do not mutate the page unless the user explicitly asks. No cookie access.",
    inputSchema: {
      column: z
        .number()
        .int()
        .min(0)
        .describe("Column index (0-based)"),
      js: z.string().min(1).describe("JavaScript source to evaluate"),
    },
    annotations: READ_ONLY,
  },
  async ({ column, js }) => {
    try {
      return jsonResult(await evalJs(column, js));
    } catch (err) {
      return errorResult(err);
    }
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("[xdeck-agent-mcp]", err);
  process.exit(1);
});
