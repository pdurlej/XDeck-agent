import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const DEFAULT_BASE = "http://127.0.0.1:18765";

export function tokenCandidates() {
  if (process.env.XDECK_AGENT_TOKEN_FILE) {
    return [process.env.XDECK_AGENT_TOKEN_FILE];
  }
  return [
    path.join("/Users/Shared/XDeck-agent", "agent.token"),
    path.join(
      os.homedir(),
      "Library",
      "Application Support",
      "XDeck",
      "agent.token"
    ),
  ];
}

export function tokenPath() {
  return tokenCandidates()[0];
}

export function readToken() {
  if (process.env.XDECK_AGENT_TOKEN) {
    return process.env.XDECK_AGENT_TOKEN.trim();
  }
  const errors = [];
  for (const file of tokenCandidates()) {
    try {
      return fs.readFileSync(file, "utf8").trim();
    } catch (err) {
      errors.push(`${file}: ${err.message}`);
    }
  }
  throw new Error(
    `Cannot read agent token. Tried: ${errors.join(" | ")}. Is Debug XDeck running with XDECK_AGENT=1?`
  );
}

export async function bridgeFetch(pathname, { method = "GET", body } = {}) {
  const base = (process.env.XDECK_AGENT_URL || DEFAULT_BASE).replace(/\/$/, "");
  const token = readToken();
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
  };
  let payload;
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }
  let res;
  try {
    res = await fetch(`${base}${pathname}`, {
      method,
      headers,
      body: payload,
    });
  } catch (err) {
    throw new Error(
      `XDeck bridge unreachable at ${base}${pathname}. Is Debug XDeck running with XDECK_AGENT=1? (${err.message})`
    );
  }
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text };
  }
  if (!res.ok) {
    const msg = json?.error || text || res.statusText;
    const error = new Error(`${method} ${pathname} → ${res.status}: ${msg}`);
    error.status = res.status;
    error.body = json;
    throw error;
  }
  return json;
}

export async function listColumns() {
  return bridgeFetch("/columns");
}

/**
 * Structured column read: tweet cards + optional raw innerText.
 * @param {number} column
 * @param {{ maxChars?: number, includeText?: boolean }} [opts]
 */
export async function readColumn(column, { maxChars, includeText = true } = {}) {
  const path = includeText
    ? `/columns/${column}/text`
    : `/columns/${column}/tweets`;
  const data = await bridgeFetch(path);
  if (
    typeof maxChars === "number" &&
    typeof data.text === "string"
  ) {
    data.text = data.text.slice(0, maxChars);
  }
  return data;
}

export async function evalJs(column, js) {
  return bridgeFetch("/eval", {
    method: "POST",
    body: { column, js },
  });
}

export async function navigateColumn(column, url) {
  return bridgeFetch("/navigate", {
    method: "POST",
    body: { column, url },
  });
}

export async function scrollColumn(column, deltaY = 800) {
  return bridgeFetch("/scroll", {
    method: "POST",
    body: { column, deltaY },
  });
}

export async function reloadColumn(column) {
  return bridgeFetch("/reload", {
    method: "POST",
    body: { column },
  });
}

export async function health() {
  return bridgeFetch("/health");
}
