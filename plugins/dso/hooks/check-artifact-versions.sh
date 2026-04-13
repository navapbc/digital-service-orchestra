#!/usr/bin/env bash
# check-artifact-versions.sh
# SessionStart hook: compare installed host-project artifact version stamps
# against the current plugin version. Emits a one-line notice when any
# artifact is stale or missing a stamp (legacy).
#
# Artifact stamps:
#   .claude/scripts/dso         — text line: "# dso-version: <ver>"
#   .claude/dso-config.conf     — text line: "# dso-version: <ver>"
#   .pre-commit-config.yaml     — YAML key:  "x-dso-version: <ver>"
#   .github/workflows/ci.yml    — YAML key:  "x-dso-version: <ver>"
#
# Plugin version source: <plugin-root>/.claude-plugin/plugin.json
# Cache:  <host-repo>/.claude/dso-artifact-check-cache  (KEY=VALUE)
#   VERSION=<ver>   — plugin version at last check
#   TIMESTAMP=<epoch> — epoch seconds of last check
# Cache is valid when VERSION == plugin_version AND age < 86400 seconds.
#
# Exit 0 always (fail-open). No stderr output.

set -uo pipefail

# ── Resolve PLUGIN_JSON path ──────────────────────────────────────────────────
# Test injection: $PLUGIN_ROOT points to the repo root (PLUGIN_ROOT env var).
#   In this mode, plugin.json lives at $PLUGIN_ROOT/<plugin-git-path>/.claude-plugin/plugin.json
# Runtime hook context: $CLAUDE_PLUGIN_ROOT points to the plugin dir.
#   In this mode, plugin.json lives at $CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json
# Fallback: resolve relative to this script's location (script is at <plugin>/hooks/).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_resolve_plugin_json() {
    # 1. PLUGIN_ROOT (test injection) — repo root convention
    if [[ -n "${PLUGIN_ROOT:-}" ]]; then
        # Derive plugin git-relative path from script location
        local _plugin_dir
        _plugin_dir="$(cd "$_SCRIPT_DIR/.." && pwd)"
        local _repo_root
        _repo_root="$(cd "$PLUGIN_ROOT" && pwd)"
        local _plugin_git_path="${_plugin_dir#"$_repo_root"/}"
        local candidate="$PLUGIN_ROOT/$_plugin_git_path/.claude-plugin/plugin.json"
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
        # PLUGIN_ROOT set but no plugin.json found → fail-open (wrong dir, e.g. empty test dir)
        echo ""
        return 0
    fi
    # 2. CLAUDE_PLUGIN_ROOT (runtime) — plugin dir convention
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        echo "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
        return 0
    fi
    # 3. Self-resolve: script is at <plugin>/hooks/check-artifact-versions.sh
    echo "$_SCRIPT_DIR/../.claude-plugin/plugin.json"
    return 0
}

PLUGIN_JSON="$(_resolve_plugin_json)"

# Fail-open on any error
trap 'exit 0' ERR

# ── Plugin source repo guard ──────────────────────────────────────────────────
# When running inside the plugin source repo, skip artifact checks — there
# are no installed host-project artifacts here.
# Detection: the script's plugin dir (one level up from hooks/) is inside the
# current repo root. In a host project, the script lives in the plugin cache
# (outside the host repo), so this check is false.
_PLUGIN_DIR="$(cd "$_SCRIPT_DIR/.." && pwd)"
_CWD_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || _CWD_REPO_ROOT=""
_in_source_repo=false
if [[ -n "$_CWD_REPO_ROOT" ]] && [[ "$_PLUGIN_DIR" = "$_CWD_REPO_ROOT"/* ]]; then
    _in_source_repo=true
fi
# Test override: DSO_SOURCE_REPO=true allows tests to simulate source repo context
if [[ "${DSO_SOURCE_REPO:-}" == "true" ]]; then
    _in_source_repo=true
fi
if [[ "$_in_source_repo" == "true" ]]; then
    exit 0
fi

# ── Read plugin version ───────────────────────────────────────────────────────
PLUGIN_VERSION=""
PLUGIN_VERSION=$(python3 -c "
import json, sys
try:
    with open('$PLUGIN_JSON') as f:
        print(json.load(f)['version'])
except Exception:
    sys.exit(1)
" 2>/dev/null) || true

# Fail-open: if version is unreadable, skip silently
if [[ -z "$PLUGIN_VERSION" ]]; then
    exit 0
fi

# ── Cache check ───────────────────────────────────────────────────────────────
CACHE_FILE=".claude/dso-artifact-check-cache"
CACHE_TTL=86400  # 24 hours in seconds

if [[ -f "$CACHE_FILE" ]]; then
    _CACHED_VERSION=""
    _CACHED_TIMESTAMP=""
    # Parse KEY=VALUE format — accept VERSION= and TIMESTAMP= keys
    while IFS='=' read -r _key _val; do
        case "$_key" in
            VERSION)   _CACHED_VERSION="$_val" ;;
            TIMESTAMP) _CACHED_TIMESTAMP="$_val" ;;
        esac
    done < "$CACHE_FILE"

    if [[ "$_CACHED_VERSION" == "$PLUGIN_VERSION" ]] && \
       [[ "$_CACHED_TIMESTAMP" =~ ^[0-9]+$ ]]; then
        _NOW="$(date +%s)"
        _AGE=$(( _NOW - _CACHED_TIMESTAMP ))
        if (( _AGE < CACHE_TTL )); then
            # Cache hit — no need to re-check
            exit 0
        fi
    fi
fi

# ── Read stamps from each artifact ───────────────────────────────────────────
# Returns extracted version, empty string if not found, or "MISSING" if file absent
_read_text_stamp() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo ""
        return 0
    fi
    local stamp
    stamp=$(grep -m1 '^# dso-version:' "$file" 2>/dev/null | sed 's/^# dso-version: *//' | tr -d '[:space:]') || true
    echo "$stamp"
}

_read_yaml_stamp() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo ""
        return 0
    fi
    local stamp
    stamp=$(grep -m1 '^x-dso-version:' "$file" 2>/dev/null | sed 's/^x-dso-version: *//' | tr -d '[:space:]') || true
    echo "$stamp"
}

_SHIM_VER="$(_read_text_stamp ".claude/scripts/dso")"
_CONFIG_VER="$(_read_text_stamp ".claude/dso-config.conf")"
_PRECOMMIT_VER="$(_read_yaml_stamp ".pre-commit-config.yaml")"
_CI_VER="$(_read_yaml_stamp ".github/workflows/ci.yml")"

# ── Compare stamps ────────────────────────────────────────────────────────────
# Classify each artifact:
#   "current"  — stamp matches plugin version
#   "stale"    — stamp exists but differs from plugin version
#   "legacy"   — file exists but has no stamp (no dso-version line)
#   "absent"   — file does not exist (not checked)

_STALE_ARTIFACTS=()
_LEGACY_ARTIFACTS=()

_classify_artifact() {
    local name="$1"
    local file="$2"
    local stamp="$3"
    # File absent → skip (no stamp expected; not installed)
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    if [[ -z "$stamp" ]]; then
        # File exists but has no stamp → legacy
        _LEGACY_ARTIFACTS+=("$name")
    elif [[ "$stamp" != "$PLUGIN_VERSION" ]]; then
        # Stamp present but mismatched → stale
        _STALE_ARTIFACTS+=("$name")
    fi
    # Else: stamp matches → current, nothing to do
}

_classify_artifact "shim (.claude/scripts/dso)"       ".claude/scripts/dso"               "$_SHIM_VER"
_classify_artifact "config (.claude/dso-config.conf)" ".claude/dso-config.conf"            "$_CONFIG_VER"
_classify_artifact "pre-commit (.pre-commit-config.yaml)" ".pre-commit-config.yaml"        "$_PRECOMMIT_VER"
_classify_artifact "ci (.github/workflows/ci.yml)"    ".github/workflows/ci.yml"           "$_CI_VER"

# ── Emit notice if any issues found ──────────────────────────────────────────
_HAS_ISSUES=0

if (( ${#_STALE_ARTIFACTS[@]} > 0 )) || (( ${#_LEGACY_ARTIFACTS[@]} > 0 )); then
    _HAS_ISSUES=1
    _MSG="DSO artifacts out of date"

    if (( ${#_STALE_ARTIFACTS[@]} > 0 )); then
        _STALE_LIST="${_STALE_ARTIFACTS[*]}"
        _MSG="${_MSG} — stale: ${_STALE_LIST}"
    fi

    if (( ${#_LEGACY_ARTIFACTS[@]} > 0 )); then
        _LEGACY_LIST="${_LEGACY_ARTIFACTS[*]}"
        _MSG="${_MSG} — legacy (no version stamp): ${_LEGACY_LIST}"
    fi

    _MSG="${_MSG}. Run: dso update-artifacts"
    echo "$_MSG"
fi

# ── Write cache ───────────────────────────────────────────────────────────────
# Write regardless of whether issues were found — cache the current check result
# so we don't re-emit on every session start for the same version.
_WRITE_CACHE=1
if [[ "$_WRITE_CACHE" == "1" ]]; then
    _NOW_TS="$(date +%s)"
    mkdir -p ".claude" 2>/dev/null || true
    printf 'VERSION=%s\nTIMESTAMP=%s\n' "$PLUGIN_VERSION" "$_NOW_TS" \
        > "$CACHE_FILE" 2>/dev/null || true
fi

exit 0
