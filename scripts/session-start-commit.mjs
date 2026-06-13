#!/usr/bin/env node

/**
 * SessionStart hook for CodeBuddy Code.
 *
 * Triggers (matcher = "clear|startup" in hooks.json):
 *   - source=startup → fresh startup, /new
 *   - source=clear   → /clear (SessionEnd also fires for the old session)
 *   - source=resume  → /resume or reconnect (no-op for commit)
 *   - source=compact → after compaction (no-op)
 *
 * With CodeBuddy's native SessionEnd hook, normal session exits are
 * committed deterministically. This hook only runs an idle-TTL sweep
 * to catch sessions orphaned by crashes (SIGKILL, process kill) where
 * SessionEnd never fired.
 *
 * Commit failure handling:
 *   On any /commit failure (OV unreachable, non-2xx, timeout) we DO NOT
 *   call clearState — we keep the state file with ovSessionId still set so
 *   the next sweep retries.
 *
 * Output schema accepts {} as a no-op.
 */

import { loadConfig } from "./config.mjs";
import { createLogger } from "./debug-log.mjs";
import { clearState, listStates } from "./session-state.mjs";

const cfg = loadConfig();
const { log, logError } = createLogger("session-start");

const IDLE_TTL_MS = (() => {
  const v = Number(process.env.OPENVIKING_CODEX_IDLE_TTL_MS);
  return Number.isFinite(v) && v > 0 ? Math.floor(v) : 1_800_000;
})();

function output(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function noop(message) {
  output(message ? { systemMessage: message } : {});
}

async function fetchJSON(path, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), cfg.captureTimeoutMs);
  try {
    const headers = { "Content-Type": "application/json" };
    if (cfg.apiKey) {
      headers["Authorization"] = `Bearer ${cfg.apiKey}`;
      headers["X-API-Key"] = cfg.apiKey;
    }
    if (cfg.account) headers["X-OpenViking-Account"] = cfg.account;
    if (cfg.user) headers["X-OpenViking-User"] = cfg.user;
    const res = await fetch(`${cfg.baseUrl}${path}`, { ...init, headers, signal: controller.signal });
    const body = await res.json().catch(() => null);
    if (!body) return null;
    if (!res.ok || body.status === "error") return null;
    return body.result ?? body;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function commitOvSession(ovSessionId) {
  if (!ovSessionId) return null;
  return fetchJSON(
    `/api/v1/sessions/${encodeURIComponent(ovSessionId)}/commit`,
    { method: "POST", body: JSON.stringify({}) },
  );
}

async function commitAndClear(state, reason) {
  if (state.ovSessionId) {
    const ovSessionId = state.ovSessionId;
    const commit = await commitOvSession(state.ovSessionId);
    if (!commit) {
      logError("commit_failed_keep_state", {
        reason,
        sessionId: state.codexSessionId,
        ovSessionId: state.ovSessionId,
      });
      return { committed: false, ovSessionId: null };
    }
    log("commit", {
      reason,
      sessionId: state.codexSessionId,
      ovSessionId,
      archived: commit.archived ?? false,
      taskId: commit.task_id,
      status: commit.status,
    });
    await clearState(state.codexSessionId);
    return { committed: true, ovSessionId };
  }
  log("clear_no_ov", { reason, sessionId: state.codexSessionId });
  await clearState(state.codexSessionId);
  return { committed: true, ovSessionId: null };
}

function describeCommittedSessions(ovSessionIds) {
  if (ovSessionIds.length === 1) return `OpenViking session ${ovSessionIds[0]} is committed`;
  if (ovSessionIds.length > 1) {
    return `OpenViking sessions ${ovSessionIds.join(", ")} are committed`;
  }
  return "OpenViking session state is cleared";
}

async function main() {
  let input;
  try {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    input = JSON.parse(Buffer.concat(chunks).toString());
  } catch {
    log("skip", { stage: "stdin_parse", reason: "invalid input" });
    noop();
    return;
  }

  const source = input.source || "unknown";
  const newSessionId = input.session_id || "unknown";
  log("start", { source, newSessionId, idleTtlMs: IDLE_TTL_MS });

  // resume and compact are no-ops — session is still active.
  if (source !== "startup" && source !== "clear") {
    log("skip", { stage: "source_check", reason: `source=${source} (only startup|clear act)` });
    noop();
    return;
  }

  const health = await fetchJSON("/health");
  if (!health) {
    logError("health_check", "server unreachable; skipping sweep");
    noop();
    return;
  }

  // -----------------------------------------------------------------
  // Idle TTL sweep: commit state files older than IDLE_TTL_MS.
  // This catches sessions orphaned by crashes where SessionEnd
  // never fired. Normal exits are handled by SessionEnd hook.
  // -----------------------------------------------------------------
  const now = Date.now();
  const states = await listStates();
  let committed = 0;
  const ovSessionIds = [];

  for (const s of states) {
    if (!s?.codexSessionId) continue;
    if (s.codexSessionId === newSessionId) continue; // skip active session
    if (typeof s.lastUpdatedAt !== "number") continue;
    if ((now - s.lastUpdatedAt) <= IDLE_TTL_MS) continue;

    log("idle_sweep", {
      sessionId: s.codexSessionId,
      ovSessionId: s.ovSessionId,
      ageMs: now - s.lastUpdatedAt,
    });
    const r = await commitAndClear(s, "idle_ttl");
    if (r.committed) {
      committed += 1;
      if (r.ovSessionId) ovSessionIds.push(r.ovSessionId);
    }
  }

  log("done", {
    source,
    committed,
    ovSessionIds,
  });

  if (committed > 0) {
    noop(describeCommittedSessions(ovSessionIds));
  } else {
    noop();
  }
}

main().catch((err) => { logError("uncaught", err); noop(); });
