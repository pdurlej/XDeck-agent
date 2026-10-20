#!/usr/bin/env node
/**
 * Live scenario eval suite against Debug XDeck agent bridge (:18765).
 *
 * Scenarios (honest pass / partial / fail):
 *  1. Feed browse — health ok + structured tweets OR honest empty; needs_human false on healthy home
 *  2. Topic search — navigate_column to search URL, ready, tweets ≥1 OR documented SPA fail
 *  3. Periodic poll — 2–3 read_column cycles with stable ids / diff; no crash
 *  4. Write honesty — post/reply/retweet return HTTP 501 (do NOT actually post)
 *  5. Eval gate — MCP tools/list omits eval_js by default; HTTP POST /eval → 404
 *  6. read_column opts — default omits raw text; `limit` truncates tweet cards
 *
 * Usage:
 *   node evals/scenarios.mjs
 *   node evals/scenarios.mjs --json /tmp/xdeck-scenario-evals.json
 *   node evals/scenarios.mjs --column 0 --query openrig --polls 3
 *
 * Env: XDECK_AGENT_URL, XDECK_AGENT_TOKEN, XDECK_AGENT_TOKEN_FILE (same as CLI)
 *      XDECK_AGENT_EVAL must be unset for scenario 5 (default).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import readline from "node:readline";
import {
  health,
  readColumn,
  navigateColumn,
  scrollColumn,
  reloadColumn,
  readToken,
  DEFAULT_BASE,
} from "../lib/client.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const opts = {
    column: 0,
    query: "openrig",
    polls: 3,
    pollDelayMs: 1500,
    jsonOut: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--column") opts.column = Number(argv[++i]);
    else if (a === "--query") opts.query = String(argv[++i]);
    else if (a === "--polls") opts.polls = Number(argv[++i]);
    else if (a === "--poll-delay-ms") opts.pollDelayMs = Number(argv[++i]);
    else if (a === "--json") opts.jsonOut = String(argv[++i]);
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: node evals/scenarios.mjs [--column N] [--query Q] [--polls N] [--json path]`);
      process.exit(0);
    }
  }
  return opts;
}

function nowMs() {
  return Date.now();
}

async function timed(fn) {
  const t0 = nowMs();
  try {
    const value = await fn();
    return { ok: true, ms: nowMs() - t0, value };
  } catch (err) {
    return {
      ok: false,
      ms: nowMs() - t0,
      error: err.message || String(err),
      status: err.status,
      body: err.body,
    };
  }
}

/** Raw POST that does not throw on 4xx/5xx — for write honesty checks. */
async function rawPost(pathname, body) {
  const base = (process.env.XDECK_AGENT_URL || DEFAULT_BASE).replace(/\/$/, "");
  const token = readToken();
  const t0 = nowMs();
  let res;
  try {
    res = await fetch(`${base}${pathname}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body ?? {}),
    });
  } catch (err) {
    return {
      ms: nowMs() - t0,
      status: 0,
      error: err.message || String(err),
      body: null,
    };
  }
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text };
  }
  return { ms: nowMs() - t0, status: res.status, body: json, error: null };
}

function tweetIds(read) {
  const tweets = Array.isArray(read?.tweets) ? read.tweets : [];
  return tweets
    .map((t) => t?.id ?? t?.tweetId ?? t?.rest_id)
    .filter((id) => id != null && String(id).length > 0)
    .map(String);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function grade(pass, partial, reason, evidence) {
  const status = pass ? "pass" : partial ? "partial" : "fail";
  return { status, reason, evidence };
}

async function scenario1FeedBrowse(column) {
  const h = await timed(() => health());
  if (!h.ok) {
    return grade(false, false, `health unreachable: ${h.error}`, { health: h });
  }
  const healthBody = h.value;
  const read = await timed(() => readColumn(column, { includeText: false }));
  if (!read.ok) {
    return grade(false, false, `read_column failed: ${read.error}`, {
      healthMs: h.ms,
      health: {
        ok: healthBody.ok,
        user: healthBody.user,
        needs_human: healthBody.needs_human,
        columnCount: healthBody.columnCount,
      },
      read,
    });
  }
  const tweetCount =
    read.value.tweetCount ??
    (Array.isArray(read.value.tweets) ? read.value.tweets.length : 0);
  const needsHuman = read.value.needs_human === true;
  const healthNeedsHuman = healthBody.needs_human === true;
  const healthyHome =
    healthBody.ok === true && !healthNeedsHuman && !needsHuman;
  const hasTweets = tweetCount >= 1;
  const honestEmpty =
    tweetCount === 0 &&
    needsHuman === false &&
    Array.isArray(read.value.tweets);

  const pass = healthyHome && (hasTweets || honestEmpty);
  const partial =
    !pass &&
    healthBody.ok === true &&
    (hasTweets || honestEmpty) &&
    (needsHuman || healthNeedsHuman);

  return grade(
    pass,
    partial,
    pass
      ? hasTweets
        ? `health ok, ${tweetCount} structured tweets, needs_human=false`
        : "health ok, honest empty tweet list, needs_human=false"
      : partial
        ? `tweets readable but needs_human flagged (health=${healthNeedsHuman}, read=${needsHuman})`
        : `failed: ok=${healthBody.ok} tweets=${tweetCount} needs_human health/read=${healthNeedsHuman}/${needsHuman}`,
    {
      healthMs: h.ms,
      readMs: read.ms,
      user: healthBody.user,
      healthNeedsHuman,
      needs_human: needsHuman,
      tweetCount,
      sampleIds: tweetIds(read.value).slice(0, 5),
      challenge: read.value.challenge ?? null,
    }
  );
}

async function scenario2TopicSearch(column, query) {
  const url = `https://x.com/search?q=${encodeURIComponent(query)}&src=typed_query&f=live`;
  const nav = await timed(() => navigateColumn(column, url));
  if (!nav.ok) {
    return grade(false, false, `navigate_column failed: ${nav.error}`, {
      url,
      navigate: nav,
    });
  }
  const n = nav.value;
  const errorShell = n.errorShell === true;
  const ready = n.ready === true || n.ok === true;
  const navTweetCount = typeof n.tweetCount === "number" ? n.tweetCount : null;

  const read = await timed(() => readColumn(column, { includeText: false }));
  const tweetCount = read.ok
    ? read.value.tweetCount ??
      (Array.isArray(read.value.tweets) ? read.value.tweets.length : 0)
    : 0;
  const spaFailDocumented =
    errorShell === true ||
    (n.ok === false && typeof n.method === "string") ||
    (ready && tweetCount === 0 && n.errorShell === true);

  const pass =
    !errorShell &&
    (navTweetCount >= 1 || tweetCount >= 1) &&
    (n.ok !== false);

  const partial =
    !pass &&
    (spaFailDocumented ||
      (read.ok && tweetCount === 0 && n.method) ||
      (errorShell && typeof n.retries === "number"));

  return grade(
    pass,
    partial,
    pass
      ? `navigate ok method=${n.method ?? "?"} tweets=${tweetCount} (navCount=${navTweetCount})`
      : partial
        ? `SPA/empty documented: errorShell=${errorShell} method=${n.method ?? "?"} ready=${n.ready} tweets=${tweetCount}`
        : `topic search failed: ok=${n.ok} errorShell=${errorShell} tweets=${tweetCount} readErr=${read.error || null}`,
    {
      url,
      navigateMs: nav.ms,
      readMs: read.ok ? read.ms : null,
      navigate: {
        ok: n.ok,
        ready: n.ready,
        method: n.method,
        tweetCount: navTweetCount,
        errorShell,
        retries: n.retries,
        waitedMs: n.waitedMs,
      },
      tweetCount,
      sampleIds: read.ok ? tweetIds(read.value).slice(0, 5) : [],
      needs_human: read.ok ? read.value.needs_human : null,
    }
  );
}

/** After reload/scroll, wait briefly for SPA cards (agents should do the same). */
async function readColumnSettled(column, { attempts = 8, delayMs = 700 } = {}) {
  let last = null;
  for (let a = 0; a < attempts; a++) {
    last = await timed(() => readColumn(column, { includeText: false }));
    if (!last.ok) return last;
    const count =
      last.value.tweetCount ??
      (Array.isArray(last.value.tweets) ? last.value.tweets.length : 0);
    const needsHuman = last.value.needs_human === true;
    if (count >= 1 || needsHuman) {
      last.settleAttempts = a + 1;
      return last;
    }
    await sleep(delayMs);
  }
  if (last) last.settleAttempts = attempts;
  return last;
}

async function scenario3Periodic(column, polls, pollDelayMs) {
  const cycles = [];
  let crashed = false;
  let crashError = null;

  for (let i = 0; i < polls; i++) {
    try {
      if (i > 0) {
        // Prefer scroll for diffing; reload once at the end to prove no crash
        if (i < polls - 1) {
          const sc = await timed(() => scrollColumn(column, 600));
          cycles.push({
            kind: "scroll",
            ok: sc.ok,
            ms: sc.ms,
            error: sc.error || null,
          });
        } else {
          const rl = await timed(() => reloadColumn(column));
          cycles.push({
            kind: "reload",
            ok: rl.ok,
            ms: rl.ms,
            error: rl.error || null,
          });
        }
      }
      const read =
        i === 0
          ? await timed(() => readColumn(column, { includeText: false }))
          : await readColumnSettled(column);
      if (!read.ok) {
        cycles.push({
          kind: "read",
          ok: false,
          ms: read.ms,
          error: read.error,
        });
        crashed = true;
        crashError = read.error;
        break;
      }
      const ids = tweetIds(read.value);
      cycles.push({
        kind: "read",
        ok: true,
        ms: read.ms,
        settleAttempts: read.settleAttempts ?? 1,
        tweetCount:
          read.value.tweetCount ??
          (Array.isArray(read.value.tweets) ? read.value.tweets.length : 0),
        ids,
        needs_human: read.value.needs_human,
      });
      if (i < polls - 1) await sleep(pollDelayMs);
    } catch (err) {
      crashed = true;
      crashError = err.message || String(err);
      cycles.push({ kind: "exception", ok: false, error: crashError });
      break;
    }
  }

  const reads = cycles.filter((c) => c.kind === "read" && c.ok);
  const idSets = reads.map((r) => new Set(r.ids));
  let stableOverlap = 0;
  if (idSets.length >= 2) {
    const first = idSets[0];
    const last = idSets[idSets.length - 1];
    for (const id of first) {
      if (last.has(id)) stableOverlap++;
    }
  }
  // Pairwise: any two consecutive non-empty reads share an id OR both empty arrays are structured
  let pairwiseOk = false;
  for (let i = 1; i < reads.length; i++) {
    const a = new Set(reads[i - 1].ids);
    const b = new Set(reads[i].ids);
    if (a.size === 0 && b.size === 0) {
      pairwiseOk = true;
      break;
    }
    for (const id of a) {
      if (b.has(id)) {
        pairwiseOk = true;
        break;
      }
    }
    if (pairwiseOk) break;
  }
  const idsComparable =
    reads.length >= 2 && reads.every((r) => Array.isArray(r.ids));

  const pass =
    !crashed &&
    reads.length >= Math.min(2, polls) &&
    idsComparable &&
    (stableOverlap > 0 || pairwiseOk || reads.every((r) => r.tweetCount === 0));

  const partial =
    !pass &&
    !crashed &&
    reads.length >= 2 &&
    idsComparable;

  return grade(
    pass,
    partial,
    pass
      ? `${reads.length} poll reads ok; stableOverlap=${stableOverlap}; pairwiseOk=${pairwiseOk}`
      : crashed
        ? `crashed: ${crashError}`
        : partial
          ? `polls completed but weak id stability (overlap=${stableOverlap})`
          : `insufficient successful reads (${reads.length}/${polls})`,
    {
      pollsRequested: polls,
      cycles,
      stableOverlap,
      pairwiseOk,
      idsComparable,
      diffPossible: idsComparable,
    }
  );
}

async function scenario4WriteHonesty() {
  const endpoints = [
    { path: "/post_tweet", body: { text: "EVAL_SHOULD_NOT_POST" } },
    { path: "/reply", body: { tweetId: "0", text: "EVAL_SHOULD_NOT_REPLY" } },
    { path: "/retweet", body: { tweetId: "0" } },
  ];
  const results = [];
  for (const ep of endpoints) {
    const r = await rawPost(ep.path, ep.body);
    results.push({
      path: ep.path,
      status: r.status,
      ms: r.ms,
      error: r.error,
      body: r.body,
      honestyPass: r.status === 501,
    });
  }
  const all501 = results.every((r) => r.honestyPass);
  const any501 = results.some((r) => r.honestyPass);
  const any2xx = results.some((r) => r.status >= 200 && r.status < 300);

  if (any2xx) {
    return grade(false, false, "UNEXPECTED success on write endpoint — abort", {
      results,
    });
  }

  return grade(
    all501,
    !all501 && any501,
    all501
      ? "all write endpoints returned 501 not implemented"
      : any501
        ? "some write endpoints returned 501; others did not"
        : `no 501 honesty: statuses=${results.map((r) => `${r.path}:${r.status}`).join(", ")}`,
    { results }
  );
}

/** MCP tools/list via short-lived stdio server (inherits env minus EVAL). */
async function listMcpTools(env) {
  const serverPath = path.resolve(__dirname, "../mcp-server.js");
  const child = spawn(process.execPath, [serverPath], {
    stdio: ["pipe", "pipe", "pipe"],
    env,
    cwd: path.resolve(__dirname, ".."),
  });
  const rl = readline.createInterface({ input: child.stdout });
  const pending = new Map();
  let nextId = 1;
  let stderr = "";
  child.stderr.on("data", (d) => {
    stderr += d.toString("utf8");
  });
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
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }, 12000);
      pending.set(id, (response) => {
        clearTimeout(timer);
        resolve(response);
      });
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }
  try {
    const init = await request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "xdeck-evals", version: "0.2.0" },
    });
    if (init.error) throw new Error(JSON.stringify(init.error));
    child.stdin.write(
      `${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} })}\n`
    );
    const listed = await request("tools/list", {});
    if (listed.error) throw new Error(JSON.stringify(listed.error));
    const names = (listed.result?.tools || []).map((t) => t.name).sort();
    return { names, stderr };
  } finally {
    try {
      child.stdin.end();
    } catch {
      /* ignore */
    }
    child.kill("SIGTERM");
  }
}

async function scenario5EvalGate() {
  const evalEnv = String(process.env.XDECK_AGENT_EVAL || "")
    .trim()
    .toLowerCase();
  const evalOptIn = ["1", "true", "yes"].includes(evalEnv);

  // Always spawn MCP without EVAL to assert default surface.
  const mcpEnv = { ...process.env };
  delete mcpEnv.XDECK_AGENT_EVAL;
  let mcp;
  try {
    mcp = await listMcpTools(mcpEnv);
  } catch (err) {
    return grade(false, false, `MCP tools/list failed: ${err.message || err}`, {
      error: String(err.message || err),
    });
  }
  const evalAbsent = !mcp.names.includes("eval_js");

  const httpEval = await rawPost("/eval", { column: 0, js: "1+1" });
  const httpColEval = await rawPost("/columns/0/eval", { js: "1+1" });
  // Bridge returns 404 when XDECK_AGENT_EVAL unset (documented).
  const http404 =
    httpEval.status === 404 && httpColEval.status === 404;

  if (evalOptIn) {
    // Suite still passes MCP default check; HTTP may be 200 if app also has EVAL.
    const pass = evalAbsent;
    return grade(
      pass,
      false,
      pass
        ? `MCP default omits eval_js; note: harness env has XDECK_AGENT_EVAL=${evalEnv} (HTTP may be enabled on app)`
        : "eval_js present in default MCP tools/list",
      {
        mcpTools: mcp.names,
        evalAbsent,
        httpEval: { status: httpEval.status, body: httpEval.body },
        httpColEval: { status: httpColEval.status, body: httpColEval.body },
        harnessEvalOptIn: true,
      }
    );
  }

  const pass = evalAbsent && http404;
  const partial = evalAbsent && !http404;
  return grade(
    pass,
    partial,
    pass
      ? "eval_js absent from tools/list; POST /eval and /columns/0/eval return 404"
      : partial
        ? `MCP omits eval_js but HTTP eval not 404 (got ${httpEval.status}/${httpColEval.status}) — rebuild app without XDECK_AGENT_EVAL`
        : `eval gate failed: mcpHasEval=${!evalAbsent} http=${httpEval.status}/${httpColEval.status}`,
    {
      mcpTools: mcp.names,
      evalAbsent,
      httpEval: { status: httpEval.status, body: httpEval.body },
      httpColEval: { status: httpColEval.status, body: httpColEval.body },
      harnessEvalOptIn: false,
    }
  );
}

async function scenario6ReadOpts(column) {
  // Ensure a home timeline (scenario 2 may leave search/empty chrome briefly).
  await timed(() => navigateColumn(column, "https://x.com/home")).catch(() => {});
  await sleep(1200);
  const full = await timed(() => readColumn(column, { includeText: false }));
  if (!full.ok) {
    return grade(false, false, `read_column failed: ${full.error}`, { full });
  }
  const hasTextDefault = typeof full.value.text === "string";
  const fullCount =
    full.value.tweetCount ??
    (Array.isArray(full.value.tweets) ? full.value.tweets.length : 0);

  const limited = await timed(() =>
    readColumn(column, { includeText: false, limit: 2 })
  );
  if (!limited.ok) {
    return grade(false, false, `read_column limit failed: ${limited.error}`, {
      limited,
    });
  }
  const limCount =
    limited.value.tweetCount ??
    (Array.isArray(limited.value.tweets) ? limited.value.tweets.length : 0);
  const limLen = Array.isArray(limited.value.tweets)
    ? limited.value.tweets.length
    : 0;

  const withText = await timed(() =>
    readColumn(column, { includeText: true, maxChars: 200 })
  );
  const textOptInOk =
    withText.ok &&
    typeof withText.value.text === "string" &&
    withText.value.text.length > 0 &&
    withText.value.text.length <= 200;

  const limitOk =
    fullCount === 0
      ? limCount === 0
      : limCount <= 2 && limLen <= 2 && limCount <= fullCount;

  const pass = !hasTextDefault && limitOk && textOptInOk;
  const partial =
    !pass && !hasTextDefault && (limitOk || textOptInOk);

  return grade(
    pass,
    partial,
    pass
      ? `default omits text; limit=2 → ${limCount} cards; includeText truncates`
      : partial
        ? `partial: noDefaultText=${!hasTextDefault} limitOk=${limitOk} textOptIn=${textOptInOk}`
        : `failed: defaultHasText=${hasTextDefault} full=${fullCount} lim=${limCount} textOptIn=${textOptInOk}`,
    {
      fullCount,
      limCount,
      hasTextDefault,
      textOptInOk,
      textLen: withText.ok ? withText.value.text?.length : null,
      fullMs: full.ms,
      limitedMs: limited.ms,
    }
  );
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const startedAt = new Date().toISOString();
  let appSha = null;
  try {
    // Best-effort: sibling git root
    const root = path.resolve(__dirname, "../..");
    const head = fs.readFileSync(path.join(root, ".git/HEAD"), "utf8").trim();
    if (head.startsWith("ref:")) {
      const ref = head.slice(5).trim();
      appSha = fs
        .readFileSync(path.join(root, ".git", ref), "utf8")
        .trim()
        .slice(0, 40);
    } else {
      appSha = head.slice(0, 40);
    }
  } catch {
    appSha = null;
  }

  const report = {
    suite: "xdeck-scenario-evals",
    startedAt,
    baseUrl: process.env.XDECK_AGENT_URL || DEFAULT_BASE,
    appSha,
    opts: {
      column: opts.column,
      query: opts.query,
      polls: opts.polls,
      pollDelayMs: opts.pollDelayMs,
    },
    scenarios: {},
  };

  console.error(`xdeck scenario evals @ ${report.baseUrl} (sha=${appSha || "?"})`);

  report.scenarios[1] = {
    name: "feed_browse",
    ...(await scenario1FeedBrowse(opts.column)),
  };
  console.error(`  1 feed_browse: ${report.scenarios[1].status} — ${report.scenarios[1].reason}`);

  report.scenarios[2] = {
    name: "topic_search",
    ...(await scenario2TopicSearch(opts.column, opts.query)),
  };
  console.error(`  2 topic_search: ${report.scenarios[2].status} — ${report.scenarios[2].reason}`);

  // After topic search, try to return home for cleaner poll (best-effort)
  await timed(() =>
    navigateColumn(opts.column, "https://x.com/home")
  ).catch(() => {});
  await sleep(1000);

  report.scenarios[3] = {
    name: "periodic_poll",
    ...(await scenario3Periodic(opts.column, opts.polls, opts.pollDelayMs)),
  };
  console.error(`  3 periodic_poll: ${report.scenarios[3].status} — ${report.scenarios[3].reason}`);

  report.scenarios[4] = {
    name: "write_honesty",
    ...(await scenario4WriteHonesty()),
  };
  console.error(`  4 write_honesty: ${report.scenarios[4].status} — ${report.scenarios[4].reason}`);

  report.scenarios[5] = {
    name: "eval_js_gated",
    ...(await scenario5EvalGate()),
  };
  console.error(`  5 eval_js_gated: ${report.scenarios[5].status} — ${report.scenarios[5].reason}`);

  report.scenarios[6] = {
    name: "read_column_opts",
    ...(await scenario6ReadOpts(opts.column)),
  };
  console.error(`  6 read_column_opts: ${report.scenarios[6].status} — ${report.scenarios[6].reason}`);

  report.finishedAt = new Date().toISOString();
  report.summary = {
    1: report.scenarios[1].status,
    2: report.scenarios[2].status,
    3: report.scenarios[3].status,
    4: report.scenarios[4].status,
    5: report.scenarios[5].status,
    6: report.scenarios[6].status,
  };

  const out = JSON.stringify(report, null, 2);
  if (opts.jsonOut) {
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
