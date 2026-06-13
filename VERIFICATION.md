# Verification SOP — CodeBuddy Code plugin (v0.6.0)

End-to-end smoke test against a live OpenViking server. Run this whenever the
hook scripts change. Takes ~3 minutes; the only async wait is OV's memory
extractor (~30–60 s).

## 0. Prereqs

- `ov` CLI installed and reachable
- `~/.openviking/ovcli.conf` (or a per-tenant variant like `ovcli.conf.bob`)
  pointing at the OV server you want to write to. The plugin sends
  `X-API-Key`, `X-OpenViking-Account`, `X-OpenViking-User` from this file.
- Node.js 22+

```bash
export OV_CONF=$HOME/.openviking/ovcli.conf.bob   # or whichever tenant
export PLUGIN=$PWD                                  # plugin root directory
export STATE_DIR=/tmp/codebuddy-plugin-verify
rm -rf "$STATE_DIR" && mkdir -p "$STATE_DIR"
```

## 1. Stop hook — first turn appends

```bash
cat > "$STATE_DIR/transcript.jsonl" <<'EOF'
{"payload":{"role":"user","content":"My favorite color is fuchsia."}}
{"payload":{"role":"assistant","content":"Got it — fuchsia noted."}}
EOF

OPENVIKING_CONFIG_FILE=$OV_CONF \
OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
echo '{"session_id":"verify-sess","transcript_path":"'"$STATE_DIR"'/transcript.jsonl"}' \
  | node $PLUGIN/scripts/auto-capture.mjs
```

Expect: `{"systemMessage":"appended 2 turn(s) to OpenViking session cx-verify-sess"}`.

State file:
```bash
cat $STATE_DIR/state/verify-sess.json
# {"codexSessionId":"verify-sess","ovSessionId":"cx-verify-sess","capturedTurnCount":2,...}
```

OV side:
```bash
OPENVIKING_CONFIG_FILE=$OV_CONF ov read viking://session/cx-verify-sess/messages.jsonl
# 2 JSONL records: user "fuchsia", assistant "noted"
```

## 2. Stop hook idempotency — re-run without changes is a no-op

```bash
echo '{"session_id":"verify-sess","transcript_path":"'"$STATE_DIR"'/transcript.jsonl"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/auto-capture.mjs
```

Expect: `{}` (no new turns). `capturedTurnCount` still 2.

## 3. Stop hook — incremental append

Append two more turns to the transcript and re-run:

```bash
cat >> "$STATE_DIR/transcript.jsonl" <<'EOF'
{"payload":{"role":"user","content":"Actually, mint green."}}
{"payload":{"role":"assistant","content":"Updated to mint green."}}
EOF

echo '{"session_id":"verify-sess","transcript_path":"'"$STATE_DIR"'/transcript.jsonl"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/auto-capture.mjs
```

Expect: `appended 2 turn(s)` (only the new ones). Re-read
`viking://session/cx-verify-sess/messages.jsonl` — 4 records now.

## 4. PreCompact — commit + reset

```bash
echo '{"session_id":"verify-sess","transcript_path":"'"$STATE_DIR"'/transcript.jsonl","trigger":"manual"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/pre-compact-capture.mjs
```

Expect: `OpenViking session cx-verify-sess is committed`.

State file: `ovSessionId` is now `null`, `capturedTurnCount` stays at 4.

OV side:
```bash
OPENVIKING_CONFIG_FILE=$OV_CONF ov ls viking://session/cx-verify-sess
# messages.jsonl is now size 0 (archived)
# history/archive_001/ exists with the committed messages
OPENVIKING_CONFIG_FILE=$OV_CONF ov read viking://session/cx-verify-sess/history/archive_001/messages.jsonl
```

## 5. Post-compact Stop — same deterministic OV session id

Append more turns and run Stop. The same OV session id should appear:

```bash
cat >> "$STATE_DIR/transcript.jsonl" <<'EOF'
{"payload":{"role":"user","content":"After compaction: I prefer serif fonts."}}
{"payload":{"role":"assistant","content":"Noted serif preference."}}
EOF

echo '{"session_id":"verify-sess","transcript_path":"'"$STATE_DIR"'/transcript.jsonl"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/auto-capture.mjs
```

Expect: `appended 2 turn(s) to OpenViking session cx-verify-sess`.

## 6. SessionEnd — deterministic full-session commit

```bash
echo '{"session_id":"verify-sess","cwd":"/tmp"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/session-end-commit.mjs
```

Expect: `OpenViking session cx-verify-sess is committed` on stdout.
After this `verify-sess.json` is gone from `$STATE_DIR/state`.

## 7. SessionStart — active-window heuristic + idle-TTL sweep

`source=startup` and `source=clear` both run the same logic
(matcher = `clear|startup`). `source=resume` is the only hard no-op.
See `DESIGN.md` §3 + §5 for the full decision tree.

### 7a. `1 active` → commit

After step 5 (pre-compact Stop), re-create a state file for testing:

```bash
NOW=$(node -e 'console.log(Date.now())')
mkdir -p "$STATE_DIR/state"
cat > "$STATE_DIR/state/test-sess.json" <<EOF
{"codexSessionId":"test-sess","ovSessionId":"cx-test-sess","capturedTurnCount":2,"createdAt":$NOW,"lastUpdatedAt":$NOW}
EOF

echo '{"session_id":"new-after-test","source":"startup","cwd":"/tmp","model":"x","permission_mode":"default","transcript_path":null,"hook_event_name":"SessionStart"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/session-start-commit.mjs
```

Expect: `OpenViking session cx-test-sess is committed`.
After this `test-sess.json` is gone from `$STATE_DIR/state`.

### 7b. `0 active` → no-op

```bash
# State dir empty (after 7a). Fire SessionStart-startup again.
echo '{"session_id":"another-fresh","source":"startup","cwd":"/tmp","model":"x","permission_mode":"default","transcript_path":null,"hook_event_name":"SessionStart"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/session-start-commit.mjs
# Expect: {} (no orphan to commit)
```

### 7c. `≥2 active` → skip; rely on idle TTL

```bash
# Manufacture two fresh state files for different session_ids.
NOW=$(node -e 'console.log(Date.now())')
mkdir -p "$STATE_DIR/state"
cat > "$STATE_DIR/state/sess-aaa.json" <<EOF
{"codexSessionId":"sess-aaa","ovSessionId":null,"capturedTurnCount":0,"createdAt":$NOW,"lastUpdatedAt":$NOW}
EOF
cat > "$STATE_DIR/state/sess-bbb.json" <<EOF
{"codexSessionId":"sess-bbb","ovSessionId":null,"capturedTurnCount":0,"createdAt":$NOW,"lastUpdatedAt":$NOW}
EOF

OPENVIKING_DEBUG=1 \
echo '{"session_id":"sess-ccc","source":"startup","cwd":"/tmp","model":"x","permission_mode":"default","transcript_path":null,"hook_event_name":"SessionStart"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/session-start-commit.mjs
```

Expect: `{}` on stdout. In `~/.openviking/logs/codebuddy-hooks.log` look for
`"branch":">=2_active","action":"skip; rely on idle TTL"`. The two state
files are still present — the skip path does not clear them.

### 7d. Idle-TTL sweep at the tail

```bash
# Backdate one of the state files to be older than IDLE_TTL_MS (default 30 min).
OLD=$(node -e 'console.log(Date.now() - 60*60*1000)')   # 1 hour ago
cat > "$STATE_DIR/state/sess-aaa.json" <<EOF
{"codexSessionId":"sess-aaa","ovSessionId":null,"capturedTurnCount":0,"createdAt":$OLD,"lastUpdatedAt":$OLD}
EOF

echo '{"session_id":"sess-ddd","source":"startup","cwd":"/tmp","model":"x","permission_mode":"default","transcript_path":null,"hook_event_name":"SessionStart"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/session-start-commit.mjs
```

Expect: log shows `idle_sweep` for `sess-aaa` (committed and cleared).
`sess-bbb.json` is still present (still fresh). `sess-aaa.json` is gone.
If `sess-bbb` was in `≥2 active` from 7c, the heuristic on this call sees
just `sess-bbb` (1 active) and commits it — that's expected and shows the
heuristic + sweep working together.

### 7e. `source=resume` → hard no-op (no commit, no sweep)

```bash
echo '{"session_id":"any","source":"resume","cwd":"/tmp","model":"x","permission_mode":"default","transcript_path":null,"hook_event_name":"SessionStart"}' \
  | OPENVIKING_CONFIG_FILE=$OV_CONF \
    OPENVIKING_CODEX_STATE_DIR=$STATE_DIR/state \
    node $PLUGIN/scripts/session-start-commit.mjs
# Expect: {} — resume neither commits nor sweeps; short reconnects fire resume too.
```

## 8. Memory extraction landed in user namespace

Wait ~60 s for OV's extractor, then:

```bash
OPENVIKING_CONFIG_FILE=$OV_CONF ov ls viking://user/<your-user>/memories/
OPENVIKING_CONFIG_FILE=$OV_CONF ov read viking://user/<your-user>/memories/profile.md
```

Expect new entries describing the captured preferences (favorite color,
serif fonts, etc.) with timestamps from this run.

## 9. CodeBuddy CLI smoke test (requires codebuddy)

```bash
# Ensure the marketplace is registered and plugin is installed (use installer or manual steps above)
codebuddy                                                              # interactive
# Have a brief conversation that mentions a clear preference,
# then /compact (manual PreCompact) to force a commit, then exit.
```

Verify with steps 4 + 8 above.

---

**Cleanup**: `rm -rf $STATE_DIR && rm -rf ~/.openviking/codex-plugin-state/verify-sess.json`
