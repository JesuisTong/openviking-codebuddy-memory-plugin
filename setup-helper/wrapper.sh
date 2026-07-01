# OpenViking codebuddy memory plugin shell wrapper.
#
# Sourced from the user's shell rc via a `[ -f ... ] && . ...` hook that the
# installer writes once.
#
# Wraps `codebuddy` in a shell function that:
#   1. Reads the user's ovcli.conf and resolves URL / API key / identity.
#   2. Syncs the cached .mcp.json (URL + bearer_token_env_var).
#   3. Execs codebuddy with a dynamically built OPENVIKING_* env prefix.
#
# Targets bash and zsh.
DEFAULT_OPENVIKING_URL="http://127.0.0.1:1933"
MARKETPLACE_NAME="openviking-plugins-local"
PLUGIN_NAME="openviking-memory"

# Walk up from $PWD looking for a project-local ovcli.conf. Echoes the
# absolute path of the first match, or nothing. Mirrors the walker in
# scripts/ov-credentials.mjs: candidates per dir are "ovcli.conf" then
# ".openviking/ovcli.conf"; stops at $HOME; capped at 16 hops. Set
# OPENVIKING_DISABLE_REPO_CONFIG=1 to opt out; set OPENVIKING_REPO_CONFIG_FILE
# to bypass the walk and pin to a specific file.
_openviking_find_repo_conf() {
  local _ov_disabled="${OPENVIKING_DISABLE_REPO_CONFIG:-}"
  case "$_ov_disabled" in
    ""|0|false|False|FALSE) : ;;
    *) return 0 ;;
  esac
  if [ -n "${OPENVIKING_REPO_CONFIG_FILE:-}" ]; then
    [ -f "$OPENVIKING_REPO_CONFIG_FILE" ] && printf '%s\n' "$OPENVIKING_REPO_CONFIG_FILE"
    return 0
  fi
  local _ov_dir="${PWD:-.}" _ov_home="" _ov_i=0 _ov_candidate _ov_parent
  if [ -n "${HOME:-}" ]; then
    _ov_home=$(cd "$HOME" 2>/dev/null && pwd -P) || _ov_home="$HOME"
  fi
  while [ "$_ov_i" -lt 16 ]; do
    for _ov_candidate in "$_ov_dir/ovcli.conf" "$_ov_dir/.openviking/ovcli.conf"; do
      if [ -f "$_ov_candidate" ]; then
        printf '%s\n' "$_ov_candidate"
        return 0
      fi
    done
    [ -n "$_ov_home" ] && [ "$_ov_dir" = "$_ov_home" ] && return 0
    _ov_parent=$(cd "$_ov_dir/.." 2>/dev/null && pwd -P)
    [ -z "$_ov_parent" ] || [ "$_ov_parent" = "$_ov_dir" ] && return 0
    _ov_dir="$_ov_parent"
    _ov_i=$((_ov_i + 1))
  done
  return 0
}

_openviking_codebuddy_exec() {
  local _ov_conf="${OPENVIKING_CLI_CONFIG_FILE:-$HOME/.openviking/ovcli.conf}"
  # Resolve a repo-local conf from cwd if the user hasn't pinned one
  # explicitly. The repo conf wins over the default, so launching codex
  # from inside a project with a project-scoped identity just works.
  local _ov_repo_conf=""
  if [ -z "${OPENVIKING_CLI_CONFIG_FILE:-}" ]; then
    _ov_repo_conf=$(_openviking_find_repo_conf)
    if [ -n "$_ov_repo_conf" ]; then
      _ov_conf="$_ov_repo_conf"
    fi
  fi
  if ! command -v node >/dev/null 2>&1; then
    command "$@"
    return
  fi

  local _ov_url _ov_key _ov_root_key _ov_account _ov_user
  if [ -f "$_ov_conf" ]; then
    local _ov_env
    _ov_env=$(node -e '
      try {
        const c = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
        const out = (k, v) => v ? `${k}=${JSON.stringify(String(v))}\n` : "";
        process.stdout.write(
          out("OV_URL", c.url) +
          out("OV_KEY", c.api_key) +
          out("OV_ROOT_KEY", c.root_api_key) +
          out("OV_ACCOUNT", c.account) +
          out("OV_USER", c.user)
        );
      } catch {}
    ' "$_ov_conf" 2>/dev/null)
    eval "$_ov_env"
  fi
  _ov_url="${OPENVIKING_URL:-${OV_URL:-${DEFAULT_OPENVIKING_URL:-}}}"
  _ov_key="${OPENVIKING_API_KEY:-${OV_KEY:-}}"
  _ov_root_key="${OPENVIKING_ROOT_API_KEY:-${OV_ROOT_KEY:-}}"
  _ov_account="${OPENVIKING_ACCOUNT:-${OV_ACCOUNT:-}}"
  _ov_user="${OPENVIKING_USER:-${OV_USER:-}}"
  unset OV_URL OV_KEY OV_ACCOUNT OV_USER

  # Sync cache .mcp.json.
  local _mcp_url_from_conf
  if [ -n "$_ov_url" ]; then
    if [ -n "${OPENVIKING_MCP_URL:-}" ]; then
      _mcp_url_from_conf="$OPENVIKING_MCP_URL"
    else
      _mcp_url_from_conf="${_ov_url%/}/mcp"
    fi
  else
    _mcp_url_from_conf=""
  fi

  _cache_mcp_folder="$HOME/.codebuddy/${MARKETPLACE_NAME}-marketplace/${PLUGIN_NAME}"
  if [ -L "$_cache_mcp_folder" ]; then
    _cache_mcp_folder="$(realpath "$_cache_mcp_folder")"
  fi
  _cache_mcp="$_cache_mcp_folder/.mcp.json"

  if [ -f "$_cache_mcp" ]; then
    # 多租户模式mcp只能存在Authorization，否则需要root-api-key和用户账号指定人员
    node -e '
      const fs = require("node:fs");
      const file = process.argv[1];
      const url = process.argv[2] || "";
      const api_key = process.argv[3] || "";
      const root_api_key = process.argv[4] || "";
      const ov_account = process.argv[5] || "";
      const ov_user = process.argv[6] || "";
      const j = JSON.parse(fs.readFileSync(file, "utf8"));
      const s = j.mcpServers && j.mcpServers["openviking-memory"];
      if (s) {
        let changed = false;
        if (url && s.url !== url) { s.url = url; changed = true; }
        const cur = s.headers.Authorization || "";
        if (api_key) {
          s.headers = {};
          s.headers.Authorization = "Bearer ${OPENVIKING_API_KEY}";
          changed = true;
        } else if (root_api_key && ov_account && ov_user) {
          s.headers = {};
          s.headers['X-API-Key'] = "${OPENVIKING_ROOT_API_KEY}";
          s.headers['X-OpenViking-Account'] = "${OPENVIKING_ACCOUNT}";
          s.headers['X-OpenViking-User'] = "${OPENVIKING_USER}";
          changed = true;
        } else if (!root_api_key && !api_key) {
          s.headers = {};
          changed = true;
        }
        if (changed) fs.writeFileSync(file, JSON.stringify(j, null, 2) + "\n");
      }
    ' "$_cache_mcp" "$_mcp_url_from_conf" "$_ov_key" "$_ov_root_key" "$_ov_account" "$_ov_user" 2>/dev/null || true
  fi

  local -a _env_args=()
  [ -n "$_ov_url" ]      && _env_args+=("OPENVIKING_URL=$_ov_url")
  [ -n "$_ov_key" ]      && _env_args+=("OPENVIKING_API_KEY=$_ov_key")
  [ -n "$_ov_root_key" ] && _env_args+=("OPENVIKING_ROOT_API_KEY=$_ov_root_key")
  [ -n "$_ov_account" ]  && _env_args+=("OPENVIKING_ACCOUNT=$_ov_account")
  [ -n "$_ov_user" ]     && _env_args+=("OPENVIKING_USER=$_ov_user")

  env "${_env_args[@]}" "$@"
}

codebuddy() { _openviking_codebuddy_exec codebuddy "$@"; }
