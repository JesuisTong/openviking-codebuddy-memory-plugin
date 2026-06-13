#!/usr/bin/env bash
#
# OpenViking Memory Plugin for CodeBuddy Code — interactive installer.
#
# One-liner:
#   bash <(curl -fsSL https://raw.githubusercontent.com/.../install.sh)
#
# Env overrides:
#   OPENVIKING_HOME, OPENVIKING_CLI_CONFIG_FILE, OPENVIKING_URL,
#   OPENVIKING_API_KEY,
#   OPENVIKING_CODEBUDDY_MARKETPLACE_ROOT

set -euo pipefail

OV_HOME="${OPENVIKING_HOME:-$HOME/.openviking}"
OVCLI_CONF="${OPENVIKING_CLI_CONFIG_FILE:-$OV_HOME/ovcli.conf}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/.."
WRAPPER_FILE="$SCRIPT_DIR/wrapper.sh"
MARKETPLACE_NAME="openviking-plugins-local"
MARKETPLACE_ROOT="${OPENVIKING_CODEBUDDY_MARKETPLACE_ROOT:-$HOME/.codebuddy/${MARKETPLACE_NAME}-marketplace}"
PLUGIN_NAME="openviking-memory"
PLUGIN_ID="${PLUGIN_NAME}@${MARKETPLACE_NAME}"
CODEX_SETTINGS="${CODEX_SETTINGS_FILE:-$HOME/.codebuddy/settings.json}"
WRAPPER_MARKER_BEGIN="# >>> openviking-codebuddy-plugin >>>"
WRAPPER_MARKER_END="# <<< openviking-codebuddy-plugin <<<"

if [ -t 1 ]; then
  CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  CYAN=''; GREEN=''; YELLOW=''; RED=''; BOLD=''; RESET=''
fi
info()    { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%s!!%s  %s\n' "$YELLOW" "$RESET" "$*"; }
err()     { printf '%sxx%s  %s\n' "$RED" "$RESET" "$*" >&2; }
ask()     { printf '%s??%s  %s' "$CYAN" "$RESET" "$*"; }
heading() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }

# ----- 1. Environment check -----

heading '1. Environment check'

need() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}
need codebuddy
need node

NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
if [ "$NODE_MAJOR" -lt 22 ]; then
  err "Node.js 22+ is required; found $(node --version)."
  exit 1
fi

if [ ! -f "$PLUGIN_DIR/.codebuddy-plugin/plugin.json" ]; then
  err "Plugin manifest not found at $PLUGIN_DIR/.codebuddy-plugin/plugin.json"
  err "This script must be run from within the plugin checkout (setup-helper/ directory)."
  exit 1
fi

info "codebuddy: $(codebuddy --version 2>/dev/null || echo unknown)"
info "node:      $(node --version)"

# ----- 2. Plugin version detection -----

heading '2. Plugin version'

PLUGIN_VERSION="$(node -e '
  const p = require(process.argv[1]);
  console.log(p.version || "0.0.0");
' "$PLUGIN_DIR/.codebuddy-plugin/plugin.json")"

info "Plugin: $PLUGIN_NAME (version $PLUGIN_VERSION)"

# ----- 3. OpenViking client config -----

heading "3. OpenViking client config ($OVCLI_CONF)"

mkdir -p "$OV_HOME"
chmod 700 "$OV_HOME" 2>/dev/null || true

ov_read_conf() {
  [ -f "$OVCLI_CONF" ] || return 0
  node -e '
    try {
      const c = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      const v = c[process.argv[2]];
      if (v) process.stdout.write(String(v));
    } catch {}
  ' "$OVCLI_CONF" "$1" 2>/dev/null || true
}

CURRENT_URL="$(ov_read_conf url)"
CURRENT_KEY="$(ov_read_conf api_key)"

if [ -t 0 ]; then
  if [ -n "$CURRENT_URL" ]; then
    info "Existing config found:"
    info "  url     = $CURRENT_URL"
    if [ -n "$CURRENT_KEY" ]; then
      info "  api_key = $(printf '%s' "$CURRENT_KEY" | cut -c1-8)…"
    else
      info "  api_key = (none, unauthenticated)"
    fi
    ask 'Reuse these values? [Y/n] '
    read -r reply || reply=""
    case "$reply" in
      n|N|no|No|NO) CURRENT_URL=""; CURRENT_KEY="" ;;
    esac
  fi

  if [ -z "$CURRENT_URL" ]; then
    # Backup existing config before overwriting
    if [ -f "$OVCLI_CONF" ]; then
      backup="$OVCLI_CONF.bak.$(date +%s)"
      cp "$OVCLI_CONF" "$backup"
      info "Backed up existing config → $backup"
    fi

    DEFAULT_URL="http://127.0.0.1:1933"
    ask "OpenViking server URL [$DEFAULT_URL]: "
    read -r URL_INPUT || URL_INPUT=""
    CURRENT_URL="${URL_INPUT:-$DEFAULT_URL}"

    ask "API key (leave empty for unauthenticated local mode): "
    if read -rs API_INPUT 2>/dev/null; then
      printf '\n'
    else
      read -r API_INPUT || API_INPUT=""
    fi
    CURRENT_KEY="$API_INPUT"

    # Merge url + api_key into any existing config so extra fields (account,
    # user, …) the wrapper reads are preserved.
    node -e '
      const fs = require("node:fs");
      const [, file, url, key] = process.argv;
      let c = {};
      try { c = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
      c.url = url;
      c.api_key = key;
      fs.writeFileSync(file, JSON.stringify(c, null, 2) + "\n");
    ' "$OVCLI_CONF" "$CURRENT_URL" "$CURRENT_KEY"
    chmod 600 "$OVCLI_CONF" 2>/dev/null || true
    info "Saved config → $OVCLI_CONF"
  else
    info "Reusing existing config."
  fi
else
  if [ -n "$CURRENT_URL" ]; then
    info "Non-interactive: using existing $OVCLI_CONF"
  else
    warn "Non-interactive and no $OVCLI_CONF — proceeding in unauthenticated mode."
    warn 'Set OPENVIKING_URL / OPENVIKING_API_KEY, or re-run in a terminal, to configure auth.'
  fi
fi

# ----- 4. Marketplace setup -----

heading "4. Marketplace setup ($MARKETPLACE_NAME)"

mkdir -p "$MARKETPLACE_ROOT/.codebuddy-plugin"

# Remove stale symlink if exists, then re-create
rm -f "$MARKETPLACE_ROOT/$PLUGIN_NAME"
ln -s "$PLUGIN_DIR" "$MARKETPLACE_ROOT/$PLUGIN_NAME"

# Write marketplace manifest
cat > "$MARKETPLACE_ROOT/.codebuddy-plugin/marketplace.json" <<EOF
{
  "name": "$MARKETPLACE_NAME",
  "plugins": [
    { "name": "$PLUGIN_NAME", "source": "./$PLUGIN_NAME" }
  ]
}
EOF

# Register marketplace
codebuddy plugin marketplace add "$MARKETPLACE_ROOT" --name "$MARKETPLACE_NAME" >/dev/null 2>&1 || true
info "Marketplace registered: $MARKETPLACE_ROOT"

# ----- 5. Plugin install & MCP rendering -----

heading "5. Plugin install ($PLUGIN_ID)"

# Run plugin install to let CodeBuddy cache the plugin
info "Installing plugin via codebuddy..."
codebuddy plugin install "$PLUGIN_ID" >/dev/null 2>&1 || {
  warn "codebuddy plugin install failed — plugin will still work via marketplace symlink"
}

# Detect whether the user has an OpenViking API key configured anywhere.
detect_api_key() {
  if [ -n "${OPENVIKING_API_KEY:-}" ] || [ -n "${OPENVIKING_BEARER_TOKEN:-}" ]; then
    echo "1"
    return
  fi
  if [ -f "$OVCLI_CONF" ]; then
    node -e '
      try {
        const c = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
        process.stdout.write(c.api_key ? "1" : "0");
      } catch { process.stdout.write("0"); }
    ' "$OVCLI_CONF" 2>/dev/null || echo "0"
    return
  fi
  echo "0"
}
HAS_API_KEY="$(detect_api_key)"

# Find and render cached .mcp.json — the wrapper syncs on every launch, but
# we also render it at install time so the initial state is correct.
_plugin_folder="$HOME/.codebuddy/${MARKETPLACE_NAME}-marketplace/${PLUGIN_NAME}"
if [ -L "$_plugin_folder" ]; then
  _plugin_folder="$(realpath "$_plugin_folder")"
fi
CACHE_GLOB="$_plugin_folder/.mcp.json"
if [ -f "$CACHE_GLOB" ]; then
  info "Rendered MCP config in $CACHE_GLOB cached .mcp.json file(s)"
  info "MCP auth: $([ "$HAS_API_KEY" = "1" ] && echo "Bearer (OPENVIKING_API_KEY)" || echo "none (unauthenticated)")"
  node - "$CACHE_GLOB" "$HAS_API_KEY" <<'NODE'
  const fs = require("node:fs");
  const [, , file, hasKey] = process.argv;
  const j = JSON.parse(fs.readFileSync(file, "utf8"));
  const s = j.mcpServers && j.mcpServers["openviking-memory"];
  if (s) {
    if (hasKey !== "1") {
      delete s.headers.Authorization;
    }
    fs.writeFileSync(file, JSON.stringify(j, null, 2) + "\n");
  }
NODE
else
  warn "No cached .mcp.json found at $CACHE_GLOB"
  warn "The wrapper will sync MCP config on each codebuddy launch instead"
fi

# ----- 6. Plugin enablement -----

heading "6. Plugin enablement"

node - "$CODEX_SETTINGS" "$PLUGIN_ID" <<'NODE'
  const fs = require("node:fs");
  const [, , file, pluginId] = process.argv;
  let settings = {};
  try {
    settings = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {}

  if (!settings.enabledPlugins) {
    settings.enabledPlugins = {};
  }
  settings.enabledPlugins[pluginId] = true;

  fs.mkdirSync(require("node:path").dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(settings, null, 2) + "\n");
NODE
info "Enabled $PLUGIN_ID in $CODEX_SETTINGS"

# ----- 7. Shell wrapper -----

heading '7. Shell wrapper'

RC_FILE=""
case "${SHELL:-}" in
  */zsh)  RC_FILE="$HOME/.zshrc" ;;
  */bash) RC_FILE="$HOME/.bashrc" ;;
  *)
    if   [ -f "$HOME/.zshrc" ];  then RC_FILE="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then RC_FILE="$HOME/.bashrc"
    else RC_FILE=""; fi
    ;;
esac

SOURCE_HOOK="[ -f \"$WRAPPER_FILE\" ] && . \"$WRAPPER_FILE\""

SOURCE_BLOCK="$WRAPPER_MARKER_BEGIN
$SOURCE_HOOK
$WRAPPER_MARKER_END"

if [ -z "$RC_FILE" ]; then
  warn 'Could not detect a shell rc. Add this snippet to your rc manually:'
  warn ''
  while IFS= read -r line; do warn "  $line"; done <<EOF
$SOURCE_BLOCK
EOF
else
  if [ -f "$RC_FILE" ] && grep -qF "$WRAPPER_MARKER_BEGIN" "$RC_FILE" 2>/dev/null; then
    # Strip the existing marker block and re-add
    if grep -qF "$WRAPPER_MARKER_END" "$RC_FILE" 2>/dev/null; then
      info "Replacing openviking source hook in $RC_FILE"
      awk -v b="$WRAPPER_MARKER_BEGIN" -v e="$WRAPPER_MARKER_END" '
        $0 == b {skip=1; next}
        $0 == e {skip=0; next}
        !skip
      ' "$RC_FILE" > "$RC_FILE.tmp" && mv "$RC_FILE.tmp" "$RC_FILE"
    else
      warn "$WRAPPER_MARKER_BEGIN found in $RC_FILE but $WRAPPER_MARKER_END is missing."
      warn 'Refusing to in-place rewrite; appending a fresh source hook instead.'
      warn 'Please remove the stray begin marker manually.'
    fi
  fi
  printf '\n%s\n' "$SOURCE_BLOCK" >> "$RC_FILE"
  info "Wrapper added to $RC_FILE"
fi

# ----- 8. Done -----

heading 'Done!'

info "Plugin:    $PLUGIN_ID (version $PLUGIN_VERSION)"
info "Config:    $OVCLI_CONF"
info "MCP:       ($([ "$HAS_API_KEY" = "1" ] && echo "Bearer auth" || echo "unauthenticated"))"
[ -n "$RC_FILE" ] && info "Shell rc:  $RC_FILE"
printf '\n'
if [ -n "$RC_FILE" ]; then
  printf '%s%sNext — run this in your shell to pick up the codebuddy() wrapper:%s\n' "$BOLD" "$YELLOW" "$RESET"
  printf '    %s%ssource %s%s\n' "$BOLD" "$CYAN" "$RC_FILE" "$RESET"
  printf '  (or just open a new terminal window)\n\n'
else
  printf '  (paste the snippet printed above into your shell rc, then restart your shell)\n\n'
fi
info 'Then:'
info '  codebuddy           # start CodeBuddy; the memory plugin will load automatically'
