# OpenViking Memory Plugin for CodeBuddy Code

Long-term semantic memory for [CodeBuddy Code](https://www.codebuddy.ai/cli), powered by [OpenViking](https://github.com/volcengine/OpenViking).

This is the CodeBuddy adaptation of the upstream [Codex memory plugin](https://github.com/volcengine/OpenViking/tree/main/examples/codex-memory-plugin), itself inspired by the same author's work on the [OpenViking coding-agent blog post](https://blog.openviking.ai/post/openviking-coding-agent/). It hooks CodeBuddy Code's lifecycle to:

- **Auto-recall** relevant memories on every `UserPromptSubmit` and inject them via `hookSpecificOutput.additionalContext`
- **Incremental capture on `Stop`** (turn end): append the new user/assistant turns to a deterministic OpenViking session id `cx-<session_id>`. No commit per turn.
- **Commit on `PreCompact`**: trigger OpenViking's memory extractor on the full pre-compact transcript before CodeBuddy summarizes it.
- **Commit on `SessionEnd`** (CodeBuddy-native): deterministic full-session commit on normal session exit — the primary cleanup mechanism.
- **Commit on `SessionStart` (source=startup|clear)**: active-window heuristic for orphan sessions, plus idle-TTL sweep as fallback (for crashes where `SessionEnd` never fires). See `DESIGN.md` for the full decision tree.

It also wires CodeBuddy up to OpenViking's native `/mcp` endpoint (streamable HTTP, Bearer auth), so the model has direct access to the `search`, `store`, `read`, `list`, `grep`, `glob`, `forget`, `add_resource`, and `health` tools — no local MCP server process to maintain.

## Quick Start

> **详细的安装步骤、验证方法、配置项与故障排查**请参见 [`INSTALL.md`](./INSTALL.md)。下面是仓库结构与手动安装路径的概要。

### One-line installer (recommended)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/JesuisTong/openviking-codebuddy-memory-plugin/main/setup-helper/install.sh)
```

The installer:

1. Checks `codebuddy` and Node.js 22+
2. Reads (or creates) `~/.openviking/ovcli.conf` — prompts for server URL and API key
3. Resolves the MCP endpoint URL
4. Registers a local `openviking-plugins-local` marketplace, symlinks this plugin into it
5. Runs `codebuddy plugin install openviking-memory@openviking-plugins-local` to cache the plugin
6. Renders the cached `.mcp.json` with the resolved MCP URL
7. Enables the plugin in `~/.codebuddy/settings.json`
8. Appends a `codebuddy()` shell function to your rc that pulls `OPENVIKING_API_KEY` / `OPENVIKING_ACCOUNT` / `OPENVIKING_USER` from `ovcli.conf` at invocation — keeps secrets out of `.mcp.json` on disk

After install:

```bash
source ~/.zshrc   # or ~/.bashrc
codebuddy         # first run: review /hooks once
```

### Manual setup

> 完整的步骤请参考 [`INSTALL.md` → 手动安装](./INSTALL.md#%E6%89%8B%E5%8A%A8%E5%AE%89%E8%A3%85)。下面是核心步骤摘要。

If you don't want the installer touching your rc, do these things yourself:

1. **Wire a `codebuddy()` shell function** that injects OpenViking creds at invocation time. The wrapper at `setup-helper/wrapper.sh` re-renders the cached `.mcp.json` bearer field on each launch — required if you swap `OPENVIKING_CLI_CONFIG_FILE` between configs with and without `api_key`. Source it directly from your rc:

   ```bash
   # In ~/.zshrc or ~/.bashrc:
   [ -f "path/to/setup-helper/wrapper.sh" ] && . "path/to/setup-helper/wrapper.sh"
   ```

2. **Add the plugin** via a local marketplace pointing at this directory:

   ```bash
   mkdir -p ~/.codebuddy/openviking-plugins-local-marketplace/.codebuddy-plugin
   ln -s "$PWD" ~/.codebuddy/openviking-plugins-local-marketplace/openviking-memory
   cat > ~/.codebuddy/openviking-plugins-local-marketplace/.codebuddy-plugin/marketplace.json <<JSON
   {
     "name": "openviking-plugins-local",
     "plugins": [
       { "name": "openviking-memory", "source": "./openviking-memory" }
     ]
   }
   JSON
   codebuddy plugin marketplace add ~/.codebuddy/openviking-plugins-local-marketplace
   ```

3. **Install and enable the plugin**:

   ```bash
   codebuddy plugin install openviking-memory@openviking-plugins-local
   ```

4. **Render the `__OPENVIKING_MCP_URL__` placeholder** in the cached `.mcp.json`. The wrapper script does this automatically on every launch, but for the initial state you can also find the cached copy at `~/.codebuddy/plugins/cache/openviking-plugins-local/openviking-memory/<version>/.mcp.json` and replace `__OPENVIKING_MCP_URL__` with your actual MCP endpoint.

Note: CodeBuddy natively supports `${CODEBUDDY_PLUGIN_ROOT}` in hooks — no manual placeholder replacement needed for `hooks.json`.

## Configuration

Connection / identity resolution order (highest to lowest, applies to both hooks and MCP):

1. **Environment variables**: `OPENVIKING_URL` / `OPENVIKING_BASE_URL`, `OPENVIKING_API_KEY` / `OPENVIKING_BEARER_TOKEN`, `OPENVIKING_ACCOUNT`, `OPENVIKING_USER`, `OPENVIKING_PEER_ID`
2. **`ovcli.conf`**: `~/.openviking/ovcli.conf` or `OPENVIKING_CLI_CONFIG_FILE`
3. **`ov.conf`**: `~/.openviking/ov.conf` or `OPENVIKING_CONFIG_FILE` (only `server.url` / `server.root_api_key` as connection fallback; tuning fields under a legacy `codebuddy.*` block are honored but deprecated — see [Tuning the plugin](#tuning-the-plugin))
4. **Built-in defaults**: `http://127.0.0.1:1933`, unauthenticated

The shell function wrapper handles step 1 for you by promoting ovcli.conf fields into env vars before exec'ing codebuddy. Hooks then re-resolve the full chain inside Node; the MCP server URL is baked into `.mcp.json` at install time and the API key flows in via `OPENVIKING_API_KEY` (referenced by `bearer_token_env_var` in `.mcp.json`).

Auth is sent as `Authorization: Bearer <api_key>` to both the REST API (used by hooks) and the `/mcp` endpoint (used by the model).

Set `OPENVIKING_PEER_ID` when multiple CodeBuddy instances share the same OpenViking user and should keep separate peer memory. Hooks pass it as request-level `peer_id` for auto-recall and captured session messages. The legacy `codebuddy.peerId` / `codebuddy.peer_id` fields in `ov.conf` are also honored, but env vars are preferred.

For **unauthenticated local OV** (`ovcli.conf` without `api_key`, or no ovcli.conf at all), `.mcp.json` is rendered *without* `bearer_token_env_var`. This avoids the MCP launch error when `bearer_token_env_var` points at an empty/unset env var.

The `codebuddy()` shell-function wrapper **re-renders this field on every codebuddy launch** based on the currently-active `ovcli.conf` (the one `OPENVIKING_CLI_CONFIG_FILE` points at, falling back to `~/.openviking/ovcli.conf`). That means you can switch between authenticated and unauthenticated OV — e.g. to isolate a benchmark run from production memory — by just changing `OPENVIKING_CLI_CONFIG_FILE` before invoking `codebuddy`, with no re-install needed. The wrapper also omits empty env-var assignments entirely (so `OPENVIKING_API_KEY=` is never passed to codebuddy), keeping `env_http_headers` for identity (`X-OpenViking-Account` / `X-OpenViking-User`) intact.

### Tuning the plugin

All plugin behavior is controlled by `OPENVIKING_*` environment variables — set them in your shell rc (`~/.zshrc` / `~/.bashrc`) so every `codebuddy` launch picks them up. The shell-function wrapper installed alongside the plugin already exports identity vars from `ovcli.conf`; tuning vars sit next to it.

```sh
# ~/.zshrc — examples
export OPENVIKING_RECALL_LIMIT=6
export OPENVIKING_CAPTURE_ASSISTANT_TURNS=1
export OPENVIKING_AUTO_COMMIT_ON_COMPACT=1
export OPENVIKING_DEBUG=1
```

Full list: see the `Misc env vars` block in `scripts/config.mjs`. Every field has a `OPENVIKING_*` counterpart and env vars always win.

#### Legacy `codebuddy` block in `ov.conf`

Earlier plugin versions configured tuning fields under a `codebuddy` block in `~/.openviking/ov.conf`. That still works for backward compat — every env var above has a camelCase counterpart (`OPENVIKING_RECALL_LIMIT` → `codebuddy.recallLimit`, etc.) — but **new deployments should prefer env vars**: this is per-machine plugin tuning, and the server-side `ov.conf` is the wrong place for it. (It's read from `ov.conf`, not `ovcli.conf`, by historical accident in `scripts/config.mjs`.)

## Architecture

```
   ┌──────────────────────────────────────────────────────────────────┐
   │                         CodeBuddy Code                            │
   └──┬─────────────┬──────────┬─────────────┬──────────┬──────────────┘
      │             │          │             │          │
 SessionStart  UserPromptSubmit Stop    PreCompact  SessionEnd
 (startup|clear)     │       (per turn)     │     (deterministic)
      │             │          │             │          │
 ┌────▼──────────┐ ┌─▼──────┐ ┌▼──────────┐ ┌▼────────┐ ┌▼────────────┐
 │ session-start │ │ auto-  │ │ auto-     │ │ pre-    │ │ session-end │
 │ -commit.mjs   │ │ recall │ │ capture   │ │ compact │ │ -commit.mjs  │
 │ (heuristic +  │ │ .mjs   │ │ .mjs      │ │ .mjs    │ │ (full commit│
 │ idle TTL)     │ │        │ │           │ │         │ │ + cleanup)   │
 └────┬──────────┘ └──┬─────┘ └─────┬─────┘ └───┬─────┘ └──────┬───────┘
      │               │              │           │              │
      │           ┌───▼──────────────▼───────────▼──────────────▼──┐
      └──────────►│              OpenViking REST API               │
                  │ /api/v1/search/find                            │
                  │ /api/v1/sessions [+/{id}/{messages,commit}]     │
                  │ /api/v1/content/read                           │
                  └─────────────────┬──────────────────────────────┘
                                    │
 CodeBuddy ◄── streamable-HTTP MCP ◄ /mcp (search, store, read, list,
                 (bearer token via       grep, glob, forget,
                  OPENVIKING_API_KEY)    add_resource, health)
```

The plugin does not bundle a local stdio MCP server. CodeBuddy talks to OpenViking's built-in `/mcp` endpoint directly via streamable HTTP, with `bearer_token_env_var: "OPENVIKING_API_KEY"` in `.mcp.json` so the key stays in `ovcli.conf` and the shell function — never on disk in `.mcp.json` itself.

## How It Works

> See [`DESIGN.md`](./DESIGN.md) for the commit decision tree — it's the source of truth for *which* OpenViking session is sealed by *which* hook event.

### SessionEnd (deterministic full-session commit)

CodeBuddy natively supports `SessionEnd`, which fires on normal session exit. `session-end-commit.mjs` commits the OV session for the just-ended CodeBuddy session. This is the **primary** cleanup mechanism — no heuristic guesswork needed.

### SessionStart commit logic (startup|clear, heuristic + idle TTL)

CodeBuddy fires `SessionStart` with one of three `source` values: `startup` (fresh process / `/new`), `resume` (`/resume` or short reconnect), and `clear` (`/clear` — the previous transcript is orphaned and a new session_id is created). `resume` is the *only* source we treat as a hard no-op; on `startup` and `clear` we run the same active-window heuristic.

`hooks.json` registers `SessionStart` with `matcher: "clear|startup"` so the dispatcher invokes the script on both sources. `session-start-commit.mjs` gates internally on `source ∈ {startup, clear}` as defense-in-depth.

On `startup` or `clear`, the script:

1. Counts state files (excluding the new session_id) whose `lastUpdatedAt` is within `OPENVIKING_CODEX_ACTIVE_WINDOW_MS` (default 2 min) of "now":
   - **0 active** → no-op (no orphan to commit)
   - **1 active** → commit it (the just-ended session)
   - **≥2 active** → skip; rely on idle TTL (we can't tell which one ended)
2. **Idle-TTL sweep at the tail**: any state file (regardless of session_id) older than `OPENVIKING_CODEX_IDLE_TTL_MS` (default 30 min) gets committed and cleared.

On any commit failure (OV unreachable, non-2xx, timeout) we **preserve state** (don't clear) so the next sweep can retry.

### Auto-recall (every UserPromptSubmit)

`auto-recall.mjs` reads `prompt` from stdin, calls `/api/v1/search/find`, ranks results, reads full content for top-ranked leaves, and emits:

```json
{ "hookSpecificOutput": { "hookEventName": "UserPromptSubmit", "additionalContext": "<relevant-memories>...</relevant-memories>" } }
```

CodeBuddy injects `additionalContext` into the model turn, so memories arrive without an extra tool call.

### Stop (turn end → `add_message`, NOT `commit`)

`auto-capture.mjs` derives one long-lived OpenViking session id per CodeBuddy `session_id` as `cx-<safe-session-id>` and incrementally appends every new user/assistant turn via `/api/v1/sessions/{id}/messages`. The `/messages` endpoint auto-creates the session on first append. Per-session state lives at `~/.openviking/codex-plugin-state/<safe-session-id>.json`. No `/commit` per turn — that would over-fragment memory extraction.

### PreCompact (deterministic commit before context loss)

`pre-compact-capture.mjs`:

1. Catch-up append for any turns Stop hasn't captured yet (race-safe via `capturedTurnCount`)
2. Commit the long-lived OV session so the extractor runs against the full pre-compact transcript
3. Reset `ovSessionId` to `null` so the next `Stop` re-derives the same `cx-<safe-session-id>` and appends the post-compact half under that deterministic OV session id

### Known gap: SIGTERM / Ctrl+C crash

CodeBuddy's `SessionEnd` hook handles normal exits deterministically, but crashes (SIGTERM, SIGKILL, Ctrl+C) skip all hooks. `/compact` and `/exit` are fully deterministic. For crash recovery:

1. The idle-TTL sweep at the next `SessionStart` commits any state file older than 30 min
2. The active-window heuristic catches recently-ended sessions on `/new` or `/clear`

## CodeBuddy hook output schema

| Hook | Input field of interest | Output channel for context injection |
|------|------------------------|--------------------------------------|
| `SessionStart`   | `source` (`startup`/`resume`/`clear`), `session_id` | `hookSpecificOutput.additionalContext` |
| `SessionEnd`     | (none)                    | (no output — side effect: full-session commit) |
| `UserPromptSubmit` | `prompt`                                 | `hookSpecificOutput.additionalContext` |
| `Stop`           | `last_assistant_message`, `transcript_path`, `session_id` | `systemMessage` (only) |
| `PreCompact`     | `trigger` (`manual`/`auto`), `transcript_path`, `session_id` | `systemMessage` (only) |

CodeBuddy Code supports `decision: "block"`; a no-op is `{}` (which is what these scripts emit when there's nothing to add).

## Plugin Structure

```
openviking-codebuddy-memory-plugin/
├── .codebuddy-plugin/
│   └── plugin.json              # Plugin manifest (hooks + mcp wiring)
├── hooks/
│   └── hooks.json               # SessionStart + SessionEnd + UserPromptSubmit + Stop + PreCompact
│                                  (uses ${CODEBUDDY_PLUGIN_ROOT} — CodeBuddy expands natively)
├── scripts/
│   ├── config.mjs               # Shared config loader (ovcli.conf + env)
│   ├── debug-log.mjs            # Structured JSONL logger
│   ├── session-state.mjs        # Per-session OV session state
│   ├── auto-recall.mjs          # UserPromptSubmit hook (REST /search/find)
│   ├── auto-capture.mjs         # Stop hook (REST /sessions/{id}/messages)
│   ├── session-start-commit.mjs # SessionStart hook (active-window + idle TTL)
│   ├── session-end-commit.mjs   # SessionEnd hook (deterministic full-session commit)
│   └── pre-compact-capture.mjs  # PreCompact hook
├── setup-helper/
│   ├── install-codebuddy.sh     # One-line installer
│   └── wrapper-codebuddy.sh     # Shell wrapper (codebuddy() function)
├── .mcp.json                    # Streamable-HTTP MCP wiring (renders __OPENVIKING_MCP_URL__)
├── DESIGN.md
├── VERIFICATION.md
└── README.md
```

No `src/`, `servers/`, `node_modules/`, or `package.json`: there is no local MCP server to build or run. All hook scripts are zero-dep `.mjs` running on CodeBuddy's bundled Node 22.

## Differences from the Claude Code Plugin

| Aspect | Claude Code Plugin | CodeBuddy Plugin |
|--------|--------------------|------------------|
| Plugin root env var | `CLAUDE_PLUGIN_ROOT` (expanded by CC) | `${CODEBUDDY_PLUGIN_ROOT}` (natively expanded by CodeBuddy) |
| `UserPromptSubmit` injection | `decision: "approve"` + `hookSpecificOutput.additionalContext` | `hookSpecificOutput.additionalContext` only |
| `Stop` decision | `decision: "approve"` no-op | `{}` no-op — only `block` is a valid decision |
| `SessionEnd` hook | Not available | **Native support** — deterministic full-session commit on exit |
| Compaction hook | n/a (Claude Code does not expose one) | `PreCompact` — full-transcript commit before context loss |
| Config section | `claude_code` | `codebuddy` |
| Default config file | `~/.openviking/ov.conf` | `~/.openviking/ovcli.conf`, falls back to `ov.conf` |
| MCP server | Local stdio (CC quirk: `.mcp.json` doesn't support env var auth) | Streamable HTTP to OpenViking's native `/mcp` (supports `bearer_token_env_var`) |

## License

Apache-2.0 — same as [OpenViking](https://github.com/volcengine/OpenViking).

## Inspiration / Acknowledgements

This project is a CodeBuddy Code adaptation of the OpenViking [Codex memory plugin](https://github.com/volcengine/OpenViking/tree/main/examples/codex-memory-plugin). The hook wiring pattern, per-session OV session id scheme (`cb-<codex-session-id>`), the PreCompact commit dance, the SessionStart active-window + idle-TTL sweep, and the secrets-out-of-`.mcp.json` shell-function trick are all carried over from the Codex plugin — only the hook surface, the marketplace name, and a few CodeBuddy-native touches (e.g. native `${CODEBUDDY_PLUGIN_ROOT}` expansion, the deterministic `SessionEnd` hook) are new.
