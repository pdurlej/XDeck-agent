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
 *  7. G1 metrics — feed cards expose numeric metrics.{replies,reposts,likes,views,bookmarks}
 *  8. G2 notifications — /notifications column returns typed notifications[]
 *  9. G3 isAd — status/conversation page can flag promoted cards (isAd)
 * 10. G4 articles — article search yields article.{title,preview} and/or media type article
 * 11. Bind listener — exactly one TCP listener on 18765 and it is 127.0.0.1 (not *)
 * 12. Bind restart — kill XDeck, relaunch within 5s; unauth /health → 401 within 15s (TIME_WAIT reclaim)
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
import { spawn, execFileSync } from "node:child_process";
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

  // (4) includeText must not dump window.__INITIAL_STATE__ / raw <script>
  const bigText = await timed(() =>
    readColumn(column, { includeText: true, maxChars: 50000 })
  );
  const raw = bigText.ok ? String(bigText.value.text || "") : "";
  const noScriptDump =
    bigText.ok &&
    !raw.includes("__INITIAL_STATE__") &&
    !/<script[\s>]/i.test(raw);

  const limitOk =
    fullCount === 0
      ? limCount === 0
      : limCount <= 2 && limLen <= 2 && limCount <= fullCount;

  const pass = !hasTextDefault && limitOk && textOptInOk && noScriptDump;
  const partial =
    !pass && !hasTextDefault && (limitOk || textOptInOk) && noScriptDump;

  return grade(
    pass,
    partial,
    pass
      ? `default omits text; limit=2 → ${limCount}; includeText strips scripts`
      : partial
        ? `partial: noDefaultText=${!hasTextDefault} limitOk=${limitOk} textOptIn=${textOptInOk} noScript=${noScriptDump}`
        : `failed: defaultHasText=${hasTextDefault} full=${fullCount} lim=${limCount} textOptIn=${textOptInOk} noScript=${noScriptDump}`,
    {
      fullCount,
      limCount,
      hasTextDefault,
      textOptInOk,
      noScriptDump,
      textLen: withText.ok ? withText.value.text?.length : null,
      bigTextLen: bigText.ok ? raw.length : null,
      fullMs: full.ms,
      limitedMs: limited.ms,
    }
  );
}

function metricSample(tweets) {
  const keys = ["replies", "reposts", "likes", "views", "bookmarks"];
  let withAny = 0;
  let numericOk = 0;
  let bookmarksNull = 0;
  let bookmarksZero = 0;
  const sample = [];
  for (const t of tweets) {
    const m = t?.metrics;
    if (!m || typeof m !== "object") continue;
    withAny++;
    let allNum = true;
    for (const k of keys) {
      if (m[k] == null) continue;
      if (typeof m[k] !== "number" || !Number.isFinite(m[k])) allNum = false;
    }
    if (allNum) numericOk++;
    if (m.bookmarks === null) bookmarksNull++;
    if (m.bookmarks === 0) bookmarksZero++;
    if (sample.length < 3) {
      sample.push({ id: t.id, handle: t.handle, metrics: m });
    }
  }
  return { withAny, numericOk, bookmarksNull, bookmarksZero, sample };
}

async function scenario7Metrics(column) {
  await timed(() => navigateColumn(column, "https://x.com/home")).catch(() => {});
  await sleep(1500);
  const read = await timed(() => readColumn(column, { includeText: false }));
  if (!read.ok) {
    return grade(false, false, `read_column failed: ${read.error}`, { read });
  }
  const tweets = Array.isArray(read.value.tweets) ? read.value.tweets : [];
  const { withAny, numericOk, bookmarksNull, bookmarksZero, sample } =
    metricSample(tweets);
  // Bug regression: inventing bookmarks:0 on every card when count isn't shown.
  const bookmarksHonest =
    withAny === 0 ||
    bookmarksNull >= 1 ||
    bookmarksZero < withAny; // not EVERY card forced to 0
  const pass = withAny >= 1 && numericOk >= 1 && bookmarksHonest;
  const partial = !pass && tweets.length >= 1 && withAny >= 1;
  return grade(
    pass,
    partial,
    pass
      ? `metrics on ${withAny}/${tweets.length} cards (bookmarks null=${bookmarksNull} zero=${bookmarksZero})`
      : partial
        ? `metrics weak / bookmarks honesty fail (null=${bookmarksNull} zero=${bookmarksZero}/${withAny})`
        : "no tweets and no metrics",
    {
      tweetCount: tweets.length,
      withAny,
      numericOk,
      bookmarksNull,
      bookmarksZero,
      sample,
    }
  );
}

async function scenario8Notifications(column) {
  const nav = await timed(() =>
    navigateColumn(column, "https://x.com/notifications")
  );
  await sleep(2000);
  const read = await timed(() => readColumn(column, { includeText: false }));
  if (!read.ok) {
    return grade(false, false, `read_column failed: ${read.error}`, { nav, read });
  }
  const events = Array.isArray(read.value.notifications)
    ? read.value.notifications
    : null;
  const allowed = new Set([
    "like",
    "repost",
    "follow",
    "mention",
    "reply",
    "other",
  ]);
  const typed =
    events &&
    events.length >= 1 &&
    events.every(
      (e) =>
        e &&
        typeof e === "object" &&
        allowed.has(e.type) &&
        Array.isArray(e.actors) &&
        typeof e.actorCount === "number"
    );
  const withTarget = (events || []).filter(
    (e) => e?.target && (e.target.text || e.target.id)
  );
  const withTargetId = withTarget.filter(
    (e) => typeof e.target?.id === "string" && e.target.id.length > 0
  );
  // Like/repost of own posts should expose target.id/url when possible.
  const targetIdOk =
    withTarget.length === 0 || withTargetId.length >= 1;
  const pass = typed === true && targetIdOk;
  const partial =
    !pass &&
    Array.isArray(events) &&
    (events.length === 0 ||
      events.some((e) => e && allowed.has(e?.type)));
  return grade(
    pass,
    partial,
    pass
      ? `notifications typed events=${events.length} targetId=${withTargetId.length}/${withTarget.length}`
      : partial
        ? `notifications array present but weak shape/target id (n=${events?.length ?? 0} targetId=${withTargetId.length}/${withTarget.length})`
        : `no notifications[] (nav ok=${nav.ok} ready=${nav.value?.ready})`,
    {
      nav: nav.ok
        ? {
            ok: nav.value?.ok,
            ready: nav.value?.ready,
            tweetCount: nav.value?.tweetCount,
            waitedMs: nav.value?.waitedMs,
          }
        : nav,
      notificationCount: read.value.notificationCount ?? events?.length ?? null,
      types: events ? [...new Set(events.map((e) => e.type))] : null,
      withTarget: withTarget.length,
      withTargetId: withTargetId.length,
      sample: events ? events.slice(0, 3) : null,
    }
  );
}

/** Scroll/wait a status conversation like a real agent until replies or ads appear. */
async function harvestStatusConversation(column, { maxScrolls = 8, delayMs = 900 } = {}) {
  let best = { tweets: [], ads: [], scrolls: 0 };
  for (let s = 0; s < maxScrolls; s++) {
    const read = await timed(() => readColumn(column, { includeText: false }));
    if (!read.ok) continue;
    const tweets = Array.isArray(read.value.tweets) ? read.value.tweets : [];
    const ads = tweets.filter((t) => t && t.isAd === true);
    if (tweets.length > best.tweets.length || ads.length > best.ads.length) {
      best = { tweets, ads, scrolls: s, read };
    }
    if (ads.length >= 1 && tweets.length >= 2) {
      return { ...best, settled: true };
    }
    // Wait for replies to hydrate, then scroll for in-thread promos
    await sleep(delayMs);
    await timed(() => scrollColumn(column, 1800)).catch(() => {});
    await sleep(Math.floor(delayMs * 0.7));
  }
  const finalRead = await timed(() => readColumn(column, { includeText: false }));
  if (finalRead.ok) {
    const tweets = Array.isArray(finalRead.value.tweets) ? finalRead.value.tweets : [];
    const ads = tweets.filter((t) => t && t.isAd === true);
    if (tweets.length > best.tweets.length || ads.length > best.ads.length) {
      best = { tweets, ads, scrolls: maxScrolls, read: finalRead };
    }
  }
  return {
    ...best,
    settled: best.tweets.length >= 1,
  };
}

async function scenario9StatusAd(column) {
  // Discover a live status URL from the feed first (hardcoded ids rot / error-shell).
  await timed(() => navigateColumn(column, "https://x.com/home")).catch(() => {});
  await sleep(1200);
  const feed = await timed(() => readColumn(column, { includeText: false }));
  const feedTweets = feed.ok && Array.isArray(feed.value.tweets) ? feed.value.tweets : [];
  const liveUrls = feedTweets
    .map((t) => t?.url)
    .filter((u) => typeof u === "string" && /\/status\/\d+/.test(u));
  // Prefer statuses with replies (promo often appears mid-thread after scroll).
  const busyUrls = feedTweets
    .filter(
      (t) =>
        t?.url &&
        typeof t?.metrics?.replies === "number" &&
        t.metrics.replies >= 3
    )
    .sort((a, b) => (b.metrics?.replies || 0) - (a.metrics?.replies || 0))
    .map((t) => t.url);
  const adUrls = feedTweets
    .filter((t) => t?.isAd && t?.url)
    .map((t) => t.url);
  const candidates = [
    ...new Set([...busyUrls, ...adUrls, ...liveUrls]),
  ].slice(0, 4);

  let nav = null;
  let harvest = { tweets: [], ads: [], scrolls: 0, settled: false };
  for (const url of candidates) {
    nav = await timed(() => navigateColumn(column, url));
    await sleep(1500);
    harvest = await harvestStatusConversation(column, {
      maxScrolls: 8,
      delayMs: 900,
    });
    if (harvest.ads.length >= 1) break;
    if (harvest.tweets.length >= 2) {
      // Conversation loaded — keep trying next candidate only if no ad yet
      // but remember this as settled.
    }
  }

  const tweets = harvest.tweets || [];
  const ads = harvest.ads || [];

  // Timeline proof of G3 fallback: promoted card with isAd and no <time>
  const timelineAdsNoTime = feedTweets.filter(
    (t) => t?.isAd === true && (t.time == null || t.time === "")
  );

  if (!candidates.length) {
    return grade(
      false,
      feedTweets.some((t) => t?.isAd),
      "no live status URLs in feed",
      { feedCount: feedTweets.length, timelineAdsNoTime: timelineAdsNoTime.length }
    );
  }

  const settled =
    tweets.length >= 1 &&
    nav?.ok &&
    nav.value?.ready === true;
  const repliesLoaded = tweets.length >= 2 || nav?.value?.repliesLoaded === true;
  const pass = ads.length >= 1 || timelineAdsNoTime.length >= 1;
  const partial = !pass && settled && repliesLoaded;
  return grade(
    pass,
    partial,
    pass
      ? ads.length >= 1
        ? `isAd on ${ads.length}/${tweets.length} status cards (scrolls=${harvest.scrolls})`
        : `isAd fallback on timeline promoted (no <time>) count=${timelineAdsNoTime.length}`
      : partial
        ? `status harvested (${tweets.length} tweets, scrolls=${harvest.scrolls}) but no isAd in viewport`
        : `status navigate/read weak: tweets=${tweets.length} ready=${nav?.value?.ready} repliesLoaded=${nav?.value?.repliesLoaded}`,
    {
      nav: nav?.ok
        ? {
            ok: nav.value?.ok,
            ready: nav.value?.ready,
            tweetCount: nav.value?.tweetCount,
            waitedMs: nav.value?.waitedMs,
            finalUrl: nav.value?.finalUrl,
            repliesLoaded: nav.value?.repliesLoaded ?? null,
          }
        : nav,
      tweetCount: tweets.length,
      adCount: ads.length,
      scrolls: harvest.scrolls,
      timelineAdsNoTime: timelineAdsNoTime.length,
      adSample: (ads.length ? ads : timelineAdsNoTime).slice(0, 2).map((t) => ({
        id: t.id,
        handle: t.handle,
        time: t.time ?? null,
        text: (t.text || "").slice(0, 80),
      })),
    }
  );
}

/** Heading-only title: short, not glued heading+body into one string. */
function articleTitleOk(title) {
  if (typeof title !== "string" || title.length < 4) return false;
  if (title.length >= 150) return false;
  // Glued heading+paragraph often has ". " mid-string then continues as body,
  // or concatenates without separator into a run-on > ~100 chars with 2+ sentences.
  const sentences = title.match(/[.!?]["')\]]*\s+[A-ZÀ-ÖØ-Þ]/g);
  if (sentences && sentences.length >= 1 && title.length > 80) return false;
  // "HeadingBody" with lowercase→Upper mid-token is rare; reject TLDR glued into title
  if (/TLDR\s*:/i.test(title) && !/^TLDR\s*:/i.test(title.trim())) return false;
  return true;
}

async function scenario10Articles(column) {
  // Avoid q=Article alone — search highlights false-positive the Article badge.
  // Include the review query that previously glued heading+body into title.
  const urls = [
    `https://x.com/search?q=${encodeURIComponent('"claude opus" filter:links -filter:replies min_retweets:50')}&src=typed_query&f=live`,
    `https://x.com/search?q=${encodeURIComponent("url:x.com/i/article")}&src=typed_query&f=live`,
    `https://x.com/search?q=${encodeURIComponent('"Artykuł" filter:links')}&src=typed_query&f=live`,
  ];
  let best = { withArticle: 0, cleanTitles: 0, tweets: [], nav: null, read: null };
  for (const url of urls) {
    const nav = await timed(() => navigateColumn(column, url));
    await sleep(2500);
    const read = await timed(() => readColumn(column, { includeText: false }));
    if (!read.ok) continue;
    const tweets = Array.isArray(read.value.tweets) ? read.value.tweets : [];
    const withArticle = tweets.filter(
      (t) =>
        (t?.article && (t.article.title || t.article.preview)) ||
        (Array.isArray(t?.media) && t.media.some((m) => m?.type === "article"))
    );
    const withTitle = withArticle.filter(
      (t) => typeof t?.article?.title === "string" && t.article.title.length > 0
    );
    const cleanTitles = withTitle.filter((t) =>
      articleTitleOk(t.article.title)
    );
    if (
      cleanTitles.length > best.cleanTitles ||
      (cleanTitles.length === best.cleanTitles &&
        withArticle.length > best.withArticle)
    ) {
      best = {
        withArticle: withArticle.length,
        withTitle: withTitle.length,
        cleanTitles: cleanTitles.length,
        tweets,
        nav,
        read,
        hits: withArticle,
      };
    }
    if (cleanTitles.length >= 1 && cleanTitles.length === withTitle.length) break;
  }
  const withTitleN = best.withTitle || 0;
  const titlesOk = withTitleN >= 1 && best.cleanTitles === withTitleN;
  const pass = titlesOk;
  const partial =
    !pass &&
    ((best.cleanTitles >= 1 && best.cleanTitles < withTitleN) ||
      (best.withArticle >= 1 && best.nav?.ok));
  return grade(
    pass,
    partial,
    pass
      ? `article titles clean ${best.cleanTitles}/${withTitleN} (len<150, no glue)`
      : partial
        ? `articles=${best.withArticle} titled=${withTitleN} clean=${best.cleanTitles} — glued/long titles remain`
        : "article search failed to settle with tweets",
    {
      nav: best.nav?.ok
        ? {
            ok: best.nav.value?.ok,
            ready: best.nav.value?.ready,
            tweetCount: best.nav.value?.tweetCount,
            waitedMs: best.nav.value?.waitedMs,
          }
        : best.nav,
      tweetCount: best.tweets.length,
      articleCount: best.withArticle,
      withTitle: withTitleN,
      cleanTitles: best.cleanTitles,
      sample: (best.hits || []).slice(0, 3).map((t) => ({
        id: t.id,
        handle: t.handle,
        article: t.article,
        titleLen: t.article?.title?.length ?? null,
        titleOk: articleTitleOk(t.article?.title),
        media: t.media,
        textLen: (t.text || "").length,
      })),
    }
  );
}

function listListen18765() {
  const port = 18765;
  let stdout = "";
  let stderr = "";
  let exitCode = 0;
  try {
    stdout = execFileSync("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN"], {
      encoding: "utf8",
    });
  } catch (err) {
    exitCode = typeof err.status === "number" ? err.status : 1;
    stdout = err.stdout?.toString?.() || err.stdout || "";
    stderr = err.stderr?.toString?.() || err.stderr || "";
  }

  const lines = String(stdout)
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("COMMAND"));

  const listeners = lines.map((line) => {
    const m = line.match(/TCP\s+(\S+):(\d+)\s+\(LISTEN\)/i);
    return {
      line,
      addr: m ? m[1] : null,
      port: m ? Number(m[2]) : null,
    };
  });

  return { port, stdout, stderr, exitCode, listeners };
}

/** Assert exactly one TCP listener on 18765 and it is 127.0.0.1 (not * / ::). */
async function scenario11BindListener() {
  const { port, stdout, stderr, exitCode, listeners } = listListen18765();

  const wildcard = listeners.some(
    (l) =>
      l.addr === "*" ||
      l.addr === "::" ||
      l.addr === "[::]" ||
      l.addr === "0.0.0.0"
  );
  const onlyLoopback =
    listeners.length === 1 && listeners[0].addr === "127.0.0.1" && listeners[0].port === port;

  if (onlyLoopback && !wildcard) {
    return grade(true, false, "exactly one 127.0.0.1:18765 listener (no wildcard)", {
      listeners,
      lsof: stdout.trim(),
    });
  }

  return grade(
    false,
    false,
    `expected exactly one 127.0.0.1:${port} listener, got ${listeners.length} (wildcard=${wildcard})`,
    { listeners, lsof: stdout.trim(), stderr: String(stderr).trim(), exitCode }
  );
}

/**
 * Kill the XDeck that owns :18765, relaunch the same .app within 5s, and require
 * unauthenticated GET /health → HTTP 401 within 15s (proves TIME_WAIT reclaim works).
 */
async function scenario12BindRestart() {
  const port = 18765;
  const base = (process.env.XDECK_AGENT_URL || DEFAULT_BASE).replace(/\/$/, "");
  let holderPid = null;
  let appPath = null;
  try {
    const out = execFileSync("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN"], {
      encoding: "utf8",
    });
    const line = out
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l && !l.startsWith("COMMAND"));
    const m = line && line.match(/^\S+\s+(\d+)\s+/);
    holderPid = m ? Number(m[1]) : null;
  } catch {
    return grade(false, false, "no listener on 18765 before restart test", {});
  }

  if (!holderPid) {
    return grade(false, false, "could not parse listener PID", {});
  }

  try {
    appPath = execFileSync("ps", ["-p", String(holderPid), "-o", "command="], {
      encoding: "utf8",
    })
      .trim()
      .replace(/\/Contents\/MacOS\/XDeck$/, "");
  } catch (err) {
    return grade(false, false, `ps failed for pid ${holderPid}: ${err.message || err}`, {
      holderPid,
    });
  }

  if (!appPath || !appPath.endsWith(".app")) {
    return grade(false, false, `could not resolve .app path from pid ${holderPid}`, {
      holderPid,
      appPath,
    });
  }

  const killStarted = nowMs();
  try {
    process.kill(holderPid, "SIGTERM");
  } catch (err) {
    return grade(false, false, `kill ${holderPid} failed: ${err.message || err}`, {
      holderPid,
      appPath,
    });
  }

  // Wait until port is no longer LISTEN (or process exits), up to ~5s budget for relaunch.
  for (let i = 0; i < 20; i++) {
    await sleep(100);
    try {
      process.kill(holderPid, 0);
    } catch {
      break;
    }
  }

  const relaunchAt = nowMs();
  const relaunchDelayMs = relaunchAt - killStarted;
  if (relaunchDelayMs > 5000) {
    return grade(false, false, `relaunch delayed ${relaunchDelayMs}ms (>5s) after kill`, {
      holderPid,
      appPath,
      relaunchDelayMs,
    });
  }

  const child = spawn("open", ["-n", "--env", "XDECK_AGENT=1", "--env", "XDECK_AGENT_EVAL=1", appPath], {
    stdio: "ignore",
  });
  await new Promise((resolve) => child.once("exit", resolve));

  const deadline = nowMs() + 15000;
  let lastStatus = 0;
  let lastError = null;
  let readyMs = null;
  while (nowMs() < deadline) {
    try {
      const res = await fetch(`${base}/health`, {
        method: "GET",
        headers: { Accept: "application/json" },
      });
      lastStatus = res.status;
      if (res.status === 401) {
        readyMs = nowMs() - relaunchAt;
        break;
      }
    } catch (err) {
      lastStatus = 0;
      lastError = err.message || String(err);
    }
    await sleep(250);
  }

  const after = listListen18765();
  const onlyLoopback =
    after.listeners.length === 1 &&
    after.listeners[0].addr === "127.0.0.1" &&
    after.listeners[0].port === port;

  if (lastStatus === 401 && onlyLoopback) {
    return grade(true, false, `health 401 in ${readyMs}ms after relaunch; single 127.0.0.1 listener`, {
      holderPid,
      appPath,
      relaunchDelayMs,
      readyMs,
      listeners: after.listeners,
      lsof: after.stdout.trim(),
    });
  }

  return grade(
    false,
    false,
    `expected unauth /health 401 within 15s + one 127.0.0.1 listener; got status=${lastStatus} listeners=${after.listeners.length}`,
    {
      holderPid,
      appPath,
      relaunchDelayMs,
      readyMs,
      lastStatus,
      lastError,
      listeners: after.listeners,
      lsof: after.stdout.trim(),
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

  report.scenarios[7] = {
    name: "g1_metrics",
    ...(await scenario7Metrics(opts.column)),
  };
  console.error(`  7 g1_metrics: ${report.scenarios[7].status} — ${report.scenarios[7].reason}`);

  report.scenarios[8] = {
    name: "g2_notifications",
    ...(await scenario8Notifications(opts.column)),
  };
  console.error(`  8 g2_notifications: ${report.scenarios[8].status} — ${report.scenarios[8].reason}`);

  report.scenarios[9] = {
    name: "g3_status_ad",
    ...(await scenario9StatusAd(opts.column)),
  };
  console.error(`  9 g3_status_ad: ${report.scenarios[9].status} — ${report.scenarios[9].reason}`);

  report.scenarios[10] = {
    name: "g4_articles",
    ...(await scenario10Articles(opts.column)),
  };
  console.error(`  10 g4_articles: ${report.scenarios[10].status} — ${report.scenarios[10].reason}`);

  report.scenarios[11] = {
    name: "bind_listener",
    ...(await scenario11BindListener()),
  };
  console.error(`  11 bind_listener: ${report.scenarios[11].status} — ${report.scenarios[11].reason}`);

  report.scenarios[12] = {
    name: "bind_restart",
    ...(await scenario12BindRestart()),
  };
  console.error(`  12 bind_restart: ${report.scenarios[12].status} — ${report.scenarios[12].reason}`);

  // Leave column on home for the next human/agent session (best-effort after restart).
  await timed(() => navigateColumn(opts.column, "https://x.com/home")).catch(() => {});

  report.finishedAt = new Date().toISOString();
  report.summary = {
    1: report.scenarios[1].status,
    2: report.scenarios[2].status,
    3: report.scenarios[3].status,
    4: report.scenarios[4].status,
    5: report.scenarios[5].status,
    6: report.scenarios[6].status,
    7: report.scenarios[7].status,
    8: report.scenarios[8].status,
    9: report.scenarios[9].status,
    10: report.scenarios[10].status,
    11: report.scenarios[11].status,
    12: report.scenarios[12].status,
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
