#!/usr/bin/env bash
set -uo pipefail
# plugin-inventory.sh
# Emits a structured inventory of plugin-provided enforcement components
# (hooks, scripts, skills) as JSON. Replaces ad-hoc ls/cat bash blocks
# inside /dso:architect-foundation Phase 3 Step 0.
#
# Usage: plugin-inventory.sh [--format json|table]
#   --format json   (default) — JSON object suitable for agent parsing
#   --format table  — human-readable table
#
# Exit codes:
#   0 — success
#   1 — usage error or plugin root missing

# ── Resolve plugin root (no hardcoded plugin path) ───────────────────────────
_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FORMAT="json"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --format) FORMAT="${2:-json}"; shift 2 ;;
        --format=*) FORMAT="${1#--format=}"; shift ;;
        -h|--help) echo "Usage: plugin-inventory.sh [--format json|table]"; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -d "$_PLUGIN_ROOT" ]]; then
    echo "[DSO ERROR] plugin root not found: $_PLUGIN_ROOT" >&2
    exit 1
fi

PLUGIN_JSON="$_PLUGIN_ROOT/.claude-plugin/plugin.json"

# ── Collect hooks ────────────────────────────────────────────────────────────
_collect_hooks() {
    local hooks_dir="$_PLUGIN_ROOT/hooks"
    [[ -d "$hooks_dir" ]] || return 0
    find "$hooks_dir" -maxdepth 1 -name "*.sh" -type f | sort | while read -r f; do
        printf '%s\n' "$(basename "$f")"
    done
}

# ── Collect scripts ──────────────────────────────────────────────────────────
# Depth 2 so scripts/onboarding/*.sh and any future subdirectories are included.
_collect_scripts() {
    local scripts_dir="$_PLUGIN_ROOT/scripts"
    [[ -d "$scripts_dir" ]] || return 0
    find "$scripts_dir" -maxdepth 2 -name "*.sh" -type f | sort | while read -r f; do
        # Emit path relative to scripts/ so subdir scripts are disambiguated.
        printf '%s\n' "${f#"$scripts_dir"/}"
    done
}

# ── Collect skills ───────────────────────────────────────────────────────────
_collect_skills() {
    local skills_dir="$_PLUGIN_ROOT/skills"
    [[ -d "$skills_dir" ]] || return 0
    find "$skills_dir" -maxdepth 2 -name "SKILL.md" -type f | sort | while read -r f; do
        printf '%s\n' "$(basename "$(dirname "$f")")"
    done
}

# ── Determine whether a hook name is referenced anywhere in wiring ──────────
# Hooks are wired via either (a) direct reference in .claude-plugin/plugin.json
# or (b) sourcing from dispatcher scripts under hooks/dispatchers/. Treat a
# hook as "wired" if its filename appears in either location.
_is_hook_wired() {
    local name="$1"
    if [[ -f "$PLUGIN_JSON" ]] && grep -q "$name" "$PLUGIN_JSON" 2>/dev/null; then
        echo "true"; return
    fi
    local dispatchers_dir="$_PLUGIN_ROOT/hooks/dispatchers"
    if [[ -d "$dispatchers_dir" ]] && grep -qr "$name" "$dispatchers_dir" 2>/dev/null; then
        echo "true"; return
    fi
    echo "false"
}

# ── JSON emit ────────────────────────────────────────────────────────────────
_emit_json() {
    printf '{\n  "plugin_root": "%s",\n' "$_PLUGIN_ROOT"
    printf '  "hooks": [\n'
    local first=1
    while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        local wired; wired="$(_is_hook_wired "$h")"
        [[ $first -eq 0 ]] && printf ',\n'
        printf '    {"name": "%s", "type": "hook", "wired": %s}' "$h" "$wired"
        first=0
    done < <(_collect_hooks)
    printf '\n  ],\n  "scripts": [\n'
    first=1
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        [[ $first -eq 0 ]] && printf ',\n'
        printf '    {"name": "%s", "type": "script"}' "$s"
        first=0
    done < <(_collect_scripts)
    printf '\n  ],\n  "skills": [\n'
    first=1
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        [[ $first -eq 0 ]] && printf ',\n'
        printf '    {"name": "%s", "type": "skill"}' "$k"
        first=0
    done < <(_collect_skills)
    printf '\n  ]\n}\n'
}

# ── Table emit ───────────────────────────────────────────────────────────────
_emit_table() {
    printf '%-40s %-8s %s\n' "Component" "Type" "Wired"
    printf '%-40s %-8s %s\n' "----------------------------------------" "--------" "-----"
    while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        printf '%-40s %-8s %s\n' "$h" "hook" "$(_is_hook_wired "$h")"
    done < <(_collect_hooks)
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        printf '%-40s %-8s %s\n' "$s" "script" "-"
    done < <(_collect_scripts)
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        printf '%-40s %-8s %s\n' "$k" "skill" "-"
    done < <(_collect_skills)
}

case "$FORMAT" in
    json) _emit_json ;;
    table) _emit_table ;;
    *) echo "Error: unknown format: $FORMAT (expected json|table)" >&2; exit 1 ;;
esac
