#!/usr/bin/env node
/**
 * Stdio MCP server for XDeck AgentBridge.
 *
 * Lab telescope into an open Debug XDeck window — not a search/post product.
 * Speaks MCP JSON-RPC over stdin/stdout (newline-delimited). Never log to stdout.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
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
} from "./lib/client.js";

const READ_ONLY = {
  readOnlyHint: true,
  destructiveHint: false,
  openWorldHint: false,
};

/** Navigate / scroll / reload change what's on screen but don't post. */
const NAV_ONLY = {
  readOnlyHint: false,
  destructiveHint: false,
  openWorldHint: true,
};

/**
 * eval_js can mutate the logged-in SPA (click Post, like, etc.).
 * Do NOT mark read-only — clients must treat it as powerful.
 */
const EVAL_POWERFUL = {
  readOnlyHint: false,
  destructiveHint: true,
  openWorldHint: true,
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
  { name: "xdeck-agent", version: "0.2.0" },
  { capabilities: { tools: {} } }
);

server.registerTool(
  "health",
  {
    title: "XDeck bridge health",
    description:
      "Check whether the local XDeck agent bridge is up (127.0.0.1:18765) and report user handle + column count. Includes needs_human + challenge probes per column (login/CAPTCHA/error shell). Requires Debug XDeck with XDECK_AGENT=1. Read-visible-column lab only — not topic search or posting.",
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
    title: "Read XDeck column (structured tweets)",
    description:
      "Read visible tweet cards from a column WebView: id, author, handle, text, time, url, plus optional metrics/article/inReplyTo/isPinned/isAd/retweetedBy/quoted/media when parseable. On /notifications also returns typed notifications[]. Sets needs_human (+ challenge.reasons) when the column looks like login, CAPTCHA, or an SPA error shell — do not treat that as feed text. Optionally include raw document.body.innerText. Only what is currently on screen.",
    inputSchema: {
      column: z.number().int().min(0).describe("Column index (0-based)"),
      include_text: z
        .boolean()
        .optional()
        .describe("Include raw innerText blob (default false — opt-in)"),
      limit: z
        .number()
        .int()
        .positive()
        .max(500)
        .optional()
        .describe("Max tweet cards to return (server-side truncate)"),
      max_chars: z
        .number()
        .int()
        .positive()
        .optional()
        .describe("Optional truncate length for raw text"),
    },
    annotations: READ_ONLY,
  },
  async ({ column, include_text, max_chars, limit }) => {
    try {
      return jsonResult(
        await readColumn(column, {
          maxChars: max_chars,
          includeText: include_text === true,
          limit,
        })
      );
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "acquire_column",
  {
    title: "Acquire agent column lease",
    description:
      "Lease a free agent-only hidden column (indices 100+ by default; type=agent, visible=false). Same logged-in WebKit session as the human deck. Returns column index + TTL. Concurrent agents get different columns; if none free → HTTP 409. Pass the same agentId to navigate_column / scroll_column.",
    inputSchema: {
      agent_id: z
        .string()
        .min(1)
        .describe("Stable id for this agent client (lease holder)"),
      ttl: z
        .number()
        .positive()
        .max(600)
        .optional()
        .describe("Lease TTL in seconds (default 120, max 600)"),
    },
    annotations: NAV_ONLY,
  },
  async ({ agent_id, ttl }) => {
    try {
      return jsonResult(await acquireColumn(agent_id, { ttl }));
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "release_column",
  {
    title: "Release agent column lease",
    description:
      "Release an agent column lease by agent_id and/or column index so another client can acquire it.",
    inputSchema: {
      agent_id: z
        .string()
        .min(1)
        .optional()
        .describe("Lease holder id (releases all columns for this agent)"),
      column: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe("Specific agent column index to release"),
    },
    annotations: NAV_ONLY,
  },
  async ({ agent_id, column }) => {
    try {
      return jsonResult(await releaseColumn({ agentId: agent_id, column }));
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "navigate_column",
  {
    title: "Navigate column URL",
    description:
      "Navigate a column to an http(s) URL (e.g. https://x.com/search?q=openrig&src=typed_query&f=live or a /status/ URL). User columns 0–n are refused by default (403) — use acquire_column + agent column + agent_id. Agent columns require a matching lease. Min navigation interval per agent column (default 5s). Returns ok/ready/tweetCount/method/waitedMs. Then call read_column.",
    inputSchema: {
      column: z.number().int().min(0).describe("Column index (0-based; agent columns typically 100+)"),
      url: z.string().url().describe("Absolute http(s) URL to load"),
      agent_id: z
        .string()
        .min(1)
        .optional()
        .describe("Required for agent columns — must match the lease holder"),
    },
    annotations: NAV_ONLY,
  },
  async ({ column, url, agent_id }) => {
    try {
      return jsonResult(await navigateColumn(column, url, { agentId: agent_id }));
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "scroll_column",
  {
    title: "Scroll column",
    description:
      "Scroll the column's timeline viewport (positive deltaY = down). User columns refused by default (403). Agent columns require matching agent_id lease.",
    inputSchema: {
      column: z.number().int().min(0).describe("Column index (0-based)"),
      delta_y: z
        .number()
        .int()
        .optional()
        .describe("Pixels to scroll (default 800)"),
      agent_id: z
        .string()
        .min(1)
        .optional()
        .describe("Required for agent columns — must match the lease holder"),
    },
    annotations: NAV_ONLY,
  },
  async ({ column, delta_y, agent_id }) => {
    try {
      return jsonResult(
        await scrollColumn(column, delta_y ?? 800, { agentId: agent_id })
      );
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "reload_column",
  {
    title: "Reload column",
    description: "Reload the column WKWebView (same as browser refresh).",
    inputSchema: {
      column: z.number().int().min(0).describe("Column index (0-based)"),
    },
    annotations: NAV_ONLY,
  },
  async ({ column }) => {
    try {
      return jsonResult(await reloadColumn(column));
    } catch (err) {
      return errorResult(err);
    }
  }
);

/**
 * eval_js is powerful (can mutate the logged-in SPA). Register only when
 * XDECK_AGENT_EVAL=1|true|yes — mirrors HTTP POST /eval gate (404 when unset).
 */
function evalOptInEnabled() {
  const v = String(process.env.XDECK_AGENT_EVAL || "")
    .trim()
    .toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

if (evalOptInEnabled()) {
  server.registerTool(
    "eval_js",
    {
      title: "Eval JS in XDeck column (powerful)",
      description:
        "Evaluate JavaScript in a column WKWebView. NOT read-only: the page is a logged-in x.com SPA — this can click, type, or post. Prefer read_column / navigate_column / scroll_column. Only use when a human explicitly asks. Requires XDECK_AGENT_EVAL=1 on both MCP and the XDeck app. No cookie dump tool.",
      inputSchema: {
        column: z.number().int().min(0).describe("Column index (0-based)"),
        js: z.string().min(1).describe("JavaScript source to evaluate"),
      },
      annotations: EVAL_POWERFUL,
    },
    async ({ column, js }) => {
      try {
        return jsonResult(await evalJs(column, js));
      } catch (err) {
        return errorResult(err);
      }
    }
  );
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("[xdeck-agent-mcp]", err);
  process.exit(1);
});
