#!/usr/bin/env node

/**
 * SessionEnd hook for CodeBuddy Code.
 *
 * CodeBuddy fires SessionEnd when a session terminates (reason: clear /
 * logout / prompt_input_exit / other). This is the cleanest session-end
 * signal — unlike Codex, CodeBuddy has native SessionEnd support, so we can
 * commit directly here instead of relying on the active-window heuristic +
 * idle TTL sweep.
 *
 * Behavior:
 *   1. Read stdin hook input (session_id, transcript_path, reason).
 *   2. Load state for this session_id.
 *   3. If the state has an ovSessionId with uncommitted turns:
 *      a. Read transcript, catch-up append any turns missed by Stop hooks.
 *      b. Commit the OV session (triggers memory extraction).
 *   4. Clear local state on success; preserve on failure for retry.
 *
 * SessionEnd output schema accepts {} as a no-op.
 */

import { readFile } from "node:fs/promises";
import { loadConfig } from "./config.mjs";
import { createLogger } from "./debug-log.mjs";
import { clearState, loadState, resolveOvSessionId, saveState } from "./session-state.mjs";

const cfg = loadConfig();
const { log, logError } = createLogger("session-end");

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

// ---------------------------------------------------------------------------
// Transcript helpers (shared with auto-capture / pre-compact)
// ---------------------------------------------------------------------------

function extractTextFromContent(content) {
  if (!content) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((b) => b && (b.type === "text" || b.type === "input_text" || b.type === "output_text"))
      .map((b) => b.text || "")
      .join("\n");
  }
  return "";
}

function parseTranscript(content) {
  try {
    const data = JSON.parse(content);
    if (Array.isArray(data)) return data;
  } catch { /* not array */ }
  const lines = content.split("\n").filter((l) => l.trim());
  const out = [];
  for (const line of lines) {
    try { out.push(JSON.parse(line)); } catch { /* skip */ }
  }
  return out;
}

function extractTurns(entries) {
  const turns = [];
  for (const entry of entries) {
    if (!entry || typeof entry !== "object") continue;
    const payload = entry.payload && typeof entry.payload === "object" ? entry.payload : entry;
    let role = payload.role;
    let text = "";

    if (typeof payload.content === "string") {
      text = payload.content;
    } else if (Array.isArray(payload.content)) {
      text = extractTextFromContent(payload.content);
    } else if (payload.message && typeof payload.message === "object") {
      role = payload.message.role || role;
      text = typeof payload.message.content === "string"
        ? payload.message.content
        : extractTextFromContent(payload.message.content);
    }

    if (role !== "user" && role !== "assistant") continue;
    if (role === "assistant" && !cfg.captureAssistantTurns) continue;
    const trimmed = text.trim();
    if (!trimmed) continue;

    const capped = trimmed.length > cfg.captureMaxLength
      ? trimmed.slice(0, cfg.captureMaxLength)
      : trimmed;
    turns.push({ role, text: capped });
  }
  return turns;
}

async function readTranscriptTurns(transcriptPath) {
  if (!transcriptPath) return [];
  try {
    const raw = await readFile(transcriptPath, "utf-8");
    if (!raw.trim()) return [];
    return extractTurns(parseTranscript(raw));
  } catch (err) {
    logError("transcript_read", err);
    return [];
  }
}

async function appendTurns(ovSessionId, turns) {
  let appended = 0;
  for (const turn of turns) {
    const body = { role: turn.role, content: turn.text };
    if (cfg.peerId) body.peer_id = cfg.peerId;
    const result = await fetchJSON(`/api/v1/sessions/${encodeURIComponent(ovSessionId)}/messages`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    if (!result) break;
    appended += 1;
  }
  return appended;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

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

  const sessionId = input.session_id || "unknown";
  const transcriptPath = input.transcript_path || null;
  const reason = input.reason || "other";
  log("start", { sessionId, transcriptPath, reason });

  const health = await fetchJSON("/health");
  if (!health) {
    logError("health_check", "server unreachable; state preserved for retry");
    noop();
    return;
  }

  const state = await loadState(sessionId);

  // Nothing to commit — clean up state file if it exists (empty session).
  if (!state.ovSessionId) {
    log("skip", { stage: "commit", reason: "no OV session to commit" });
    await clearState(sessionId);
    noop();
    return;
  }

  // Catch-up: append any turns the Stop hook hasn't captured yet.
  const allTurns = await readTranscriptTurns(transcriptPath);
  const newTurns = allTurns.slice(state.capturedTurnCount);

  log("transcript_parse", {
    totalTurns: allTurns.length,
    previouslyCaptured: state.capturedTurnCount,
    newTurns: newTurns.length,
  });

  if (newTurns.length > 0) {
    const ovSessionId = resolveOvSessionId(state);
    const added = await appendTurns(ovSessionId, newTurns);
    state.capturedTurnCount += added;
    log("appended_catchup", { ovSessionId, added });
    if (added < newTurns.length) {
      logError("append_failed_keep_state", { ovSessionId, attempted: newTurns.length, added });
      await saveState(state);
      noop(`SessionEnd catch-up append incomplete for ${ovSessionId}; state preserved for retry`);
      return;
    }
  }

  const ovSessionId = state.ovSessionId;
  const commit = await fetchJSON(
    `/api/v1/sessions/${encodeURIComponent(ovSessionId)}/commit`,
    { method: "POST", body: JSON.stringify({}) },
  );

  if (!commit) {
    logError("commit_failed_keep_state", { ovSessionId });
    await saveState(state);
    noop(`SessionEnd commit attempted on ${ovSessionId}; result unavailable (state preserved for retry)`);
    return;
  }

  log("commit", {
    ovSessionId,
    reason: input.reason,
    archived: commit.archived ?? false,
    taskId: commit.task_id,
    status: commit.status,
  });

  // Success: clean up local state.
  await clearState(sessionId);
  noop(`OpenViking session ${ovSessionId} is committed`);
}

main().catch((err) => { logError("uncaught", err); noop(); });
