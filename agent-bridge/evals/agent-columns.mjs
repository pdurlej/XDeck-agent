#!/usr/bin/env node
/**
 * Agent-only hidden columns — live evals.
 *
 * Requires Debug XDeck with this feature built (agent columns 100+).
 * Does NOT set XDECK_EVAL_ALLOW_BRIDGE_KILL — never kills the shared bridge.
 *
 * Usage:
 *   node evals/agent-columns.mjs
 *   node evals/agent-columns.mjs --json /tmp/agent-columns-eval.json --query openrig
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  health,
  listColumns,
  readColumn,
  navigateColumn,
  scrollColumn,
  acquireColumn,
  releaseColumn,
  DEFAULT_BASE,
} from "../lib/client.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const opts = { query: "openrig", jsonOut: null, leaseTtl: 8 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--query") opts.query = String(argv[++i]);
    else if (a === "--json") opts.jsonOut = String(argv[++i]);
    else if (a === "--lease-ttl") opts.leaseTtl = Number(argv[++i]);
  }
  return opts;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function timed(fn) {
  const t0 = Date.now();
  try {
    return { ok: true, ms: Date.now() - t0, value: await fn() };
  } catch (err) {
    return {
      ok: false,
      ms: Date.now() - t0,
      error: err.message || String(err),
      status: err.status,
      body: err.body,
    };
  }
}

function parsePacingWaitMs(nav) {
  if (!nav || nav.ok) return null;
  const msg = String(nav.error || nav.body?.error || "");
  if (nav.status !== 429 && !/pacing|Too Many Requests/i.test(msg)) return null;
  const m = msg.match(/wait\s+(\d+)\s*ms/i);
  return m ? Number(m[1]) : 5000;
}

async function navigateWithRetry(column, url, { agentId, attempts = 5 } = {}) {
  let last = null;
  for (let i = 0; i < attempts; i++) {
    last = await timed(() =>
      navigateColumn(column, url, agentId ? { agentId } : {})
    );
    if (last.ok) return last;
    if (last.status === 403) return last;
    const waitMs = parsePacingWaitMs(last);
    if (waitMs == null || i === attempts - 1) return last;
    await sleep(waitMs + 150);
  }
  return last;
}

function grade(pass, partial, reason, evidence) {
  return {
    status: pass ? "pass" : partial ? "partial" : "fail",
    reason,
    evidence,
  };
}

async function rawPost(pathname, body) {
  const { readToken } = await import("../lib/client.js");
  const base = (process.env.XDECK_AGENT_URL || DEFAULT_BASE).replace(/\/$/, "");
  const token = readToken();
  const res = await fetch(`${base}${pathname}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body ?? {}),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text };
  }
  return { status: res.status, body: json };
}

/** A1: two concurrent acquires → different agent columns */
async function evalConcurrentLeases() {
  const a = await timed(() => acquireColumn("eval-client-a", { ttl: 60 }));
  const b = await timed(() => acquireColumn("eval-client-b", { ttl: 60 }));
  const evidence = { a, b };
  if (!a.ok || !b.ok) {
    await releaseColumn({ agentId: "eval-client-a" }).catch(() => {});
    await releaseColumn({ agentId: "eval-client-b" }).catch(() => {});
    return grade(false, false, `acquire failed: a=${a.error} b=${b.error}`, evidence);
  }
  const ca = a.value.column;
  const cb = b.value.column;
  const different = ca !== cb;
  const bothAgent = ca >= 100 && cb >= 100;
  await releaseColumn({ agentId: "eval-client-a" }).catch(() => {});
  await releaseColumn({ agentId: "eval-client-b" }).catch(() => {});
  return grade(
    different && bothAgent,
    false,
    different && bothAgent
      ? `concurrent leases → columns ${ca} and ${cb}`
      : `expected different agent columns ≥100; got ${ca}, ${cb}`,
    evidence
  );
}

/** A2: search on agent column with visibilityState visible + scroll extends list */
async function evalAgentSearchScroll(query) {
  const agentId = "eval-search-scout";
  const acq = await timed(() => acquireColumn(agentId, { ttl: 180 }));
  if (!acq.ok) {
    return grade(false, false, `acquire failed: ${acq.error}`, { acq });
  }
  const column = acq.value.column;
  const userBefore = await timed(() => health());
  const col0Before = (userBefore.value?.columns || []).find((c) => c.index === 0);
  const url0 = col0Before?.url;
  const searchUrl = `https://x.com/search?q=${encodeURIComponent(query)}&src=typed_query&f=live`;

  try {
    const nav = await navigateWithRetry(column, searchUrl, { agentId });
    if (!nav.ok) {
      return grade(false, false, `navigate agent column failed: ${nav.error}`, {
        column,
        nav,
        col0Before,
      });
    }
    await sleep(1500);
    const h = await timed(() => health());
    const agentCol = (h.value?.columns || []).find((c) => c.index === column);
    const vis = agentCol?.visibilityState;
    const read1 = await timed(() => readColumn(column, { includeText: false }));
    const count1 =
      read1.value?.tweetCount ??
      (Array.isArray(read1.value?.tweets) ? read1.value.tweets.length : 0);

    await timed(() => scrollColumn(column, 1600, { agentId }));
    await sleep(1200);
    await timed(() => scrollColumn(column, 1600, { agentId }));
    await sleep(1200);
    const read2 = await timed(() => readColumn(column, { includeText: false }));
    const count2 =
      read2.value?.tweetCount ??
      (Array.isArray(read2.value?.tweets) ? read2.value.tweets.length : 0);

    const hAfter = await timed(() => health());
    const col0After = (hAfter.value?.columns || []).find((c) => c.index === 0);
    const userUnchanged = col0After?.url === url0;

    const visOk = vis === "visible" || vis === '"visible"';
    const hasTweets = count1 >= 1 || count2 >= 1;
    const scrollGrew = count2 >= count1;
    const pass = visOk && hasTweets && userUnchanged;
    const partial = !pass && (visOk || hasTweets);

    return grade(
      pass,
      partial,
      pass
        ? `agent search ok visibilityState=${vis} tweets ${count1}→${count2}; column0 url unchanged`
        : `vis=${vis} tweets ${count1}→${count2} userUnchanged=${userUnchanged}`,
      {
        column,
        visibilityState: vis,
        count1,
        count2,
        scrollGrew,
        userUnchanged,
        url0,
        url0After: col0After?.url,
        navigate: nav.value,
        sampleIds: (read2.value?.tweets || [])
          .slice(0, 5)
          .map((t) => t?.id)
          .filter(Boolean),
        agentColumn: agentCol,
      }
    );
  } finally {
    await releaseColumn({ agentId }).catch(() => {});
  }
}

/** A3: navigate column 0 without opt-in → 403 */
async function evalUserNavForbidden() {
  const res = await rawPost("/navigate", {
    column: 0,
    url: "https://x.com/explore",
  });
  const pass = res.status === 403;
  return grade(
    pass,
    false,
    pass
      ? `navigate column 0 → 403 as expected`
      : `expected 403, got ${res.status}`,
    res
  );
}

/** A4: lease expiry reclaim */
async function evalLeaseExpiry(ttlSeconds) {
  const agentId = "eval-lease-expire";
  const acq = await timed(() =>
    acquireColumn(agentId, { ttl: Math.max(2, ttlSeconds) })
  );
  if (!acq.ok) {
    return grade(false, false, `acquire failed: ${acq.error}`, { acq });
  }
  const column = acq.value.column;
  // Do not release — wait for TTL, then another agent should get same or any free.
  await sleep((Math.max(2, ttlSeconds) + 2) * 1000);
  const other = await timed(() =>
    acquireColumn("eval-lease-reclaim", { ttl: 30 })
  );
  await releaseColumn({ agentId: "eval-lease-reclaim" }).catch(() => {});
  await releaseColumn({ agentId }).catch(() => {});
  const pass = other.ok === true;
  return grade(
    pass,
    false,
    pass
      ? `after TTL, reclaim acquired column ${other.value?.column} (expired was ${column})`
      : `reclaim after TTL failed: ${other.error}`,
    { acq, other, ttlSeconds }
  );
}

/** A5: list_columns / health expose agent type + visible:false */
async function evalListHealthShape() {
  const h = await timed(() => health());
  const cols = await timed(() => listColumns());
  if (!h.ok || !cols.ok) {
    return grade(false, false, `health/list failed`, { h, cols });
  }
  const agents = (h.value.columns || []).filter((c) => c.type === "agent");
  const listed = (cols.value.columns || []).filter((c) => c.type === "agent");
  const allHidden =
    agents.length > 0 && agents.every((c) => c.visible === false);
  const indicesOk = agents.every((c) => c.index >= 100);
  const visOk = agents.every(
    (c) => c.visibilityState === "visible" || c.visibilityState === '"visible"'
  );
  const pass = agents.length >= 1 && allHidden && indicesOk && listed.length >= 1;
  const partial = agents.length >= 1 && allHidden && !visOk;
  return grade(
    pass && visOk,
    partial,
    pass && visOk
      ? `health lists ${agents.length} agent columns (visible:false, visibilityState visible)`
      : `agents=${agents.length} hidden=${allHidden} visOk=${visOk}`,
    {
      agentColumnCount: h.value.agentColumnCount,
      agents,
      listed,
    }
  );
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const report = {
    suite: "xdeck-agent-columns",
    startedAt: new Date().toISOString(),
    baseUrl: process.env.XDECK_AGENT_URL || DEFAULT_BASE,
    bridgeKillAllowed: Boolean(process.env.XDECK_EVAL_ALLOW_BRIDGE_KILL),
    scenarios: {},
  };

  if (report.bridgeKillAllowed) {
    console.error(
      "WARNING: XDECK_EVAL_ALLOW_BRIDGE_KILL is set — this suite still will not kill the bridge"
    );
  }

  console.error(`agent-columns evals @ ${report.baseUrl}`);

  report.scenarios.list_health = {
    name: "list_health_agent_shape",
    ...(await evalListHealthShape()),
  };
  console.error(
    `  list_health: ${report.scenarios.list_health.status} — ${report.scenarios.list_health.reason}`
  );

  report.scenarios.concurrent = {
    name: "concurrent_leases",
    ...(await evalConcurrentLeases()),
  };
  console.error(
    `  concurrent: ${report.scenarios.concurrent.status} — ${report.scenarios.concurrent.reason}`
  );

  report.scenarios.user_nav_403 = {
    name: "user_nav_forbidden",
    ...(await evalUserNavForbidden()),
  };
  console.error(
    `  user_nav_403: ${report.scenarios.user_nav_403.status} — ${report.scenarios.user_nav_403.reason}`
  );

  report.scenarios.agent_search = {
    name: "agent_search_scroll_visibility",
    ...(await evalAgentSearchScroll(opts.query)),
  };
  console.error(
    `  agent_search: ${report.scenarios.agent_search.status} — ${report.scenarios.agent_search.reason}`
  );

  report.scenarios.lease_expiry = {
    name: "lease_expiry_reclaim",
    ...(await evalLeaseExpiry(opts.leaseTtl)),
  };
  console.error(
    `  lease_expiry: ${report.scenarios.lease_expiry.status} — ${report.scenarios.lease_expiry.reason}`
  );

  report.finishedAt = new Date().toISOString();
  report.summary = Object.fromEntries(
    Object.entries(report.scenarios).map(([k, v]) => [k, v.status])
  );

  const out = JSON.stringify(report, null, 2);
  if (opts.jsonOut) {
    fs.mkdirSync(path.dirname(opts.jsonOut), { recursive: true });
    fs.writeFileSync(opts.jsonOut, out + "\n");
    console.error(`wrote ${opts.jsonOut}`);
  }
  console.log(out);

  const failed = Object.values(report.summary).some((s) => s === "fail");
  process.exit(failed ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(2);
});
