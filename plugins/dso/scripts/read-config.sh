#!/usr/bin/env bash
set -uo pipefail
# scripts/read-config.sh
# Config reader for .claude/dso-config.conf (canonical) with legacy YAML fallback.
#
# Canonical config format: flat key=value (.claude/dso-config.conf). See CONFIGURATION-REFERENCE.md.
#
# This is the foundation layer that config-paths.sh depends on to resolve
# project paths. It reads raw config values from flat .conf or YAML files.
#
# Usage (key-first):  read-config.sh [--list] [--batch] <key> [config-file]
# Usage (config-first): read-config.sh [--list] [--batch] <config-file> <key>
#
# Supports:
#   - Flat key=value format (dot-notation keys like "tickets.sync.jira_project_key") — canonical
#   - YAML format with nested keys (legacy migration-compat fallback; .conf takes precedence per
#     FLAT-CONFIG-MIGRATION.md; YAML support is intentionally retained for projects still migrating)
#   - List mode with --list flag (returns value on one line; exit 1 if absent)
#   - Batch mode with --batch flag (outputs all keys as UPPER_CASE_WITH_UNDERSCORES=value)
#   - Missing file → empty output, exit 0
#   - Absent key in scalar mode → empty output, exit 0
#   - Absent key in --list mode → exit 1
#
# Exit codes:
#   0 — success, missing file, or missing key (scalar mode)
#   1 — missing key in --list mode (distinguishes "empty" from "absent")

list_mode=""; batch_mode=""; [[ "${1:-}" == "--list" ]] && { list_mode=1; shift; }
[[ "${1:-}" == "--batch" ]] && { batch_mode=1; shift; }

# Detect config-first form: first arg contains '/' or ends with .conf/.yaml/.yml
arg1="${1:-}"
if [[ "$arg1" == *"/"* || "$arg1" == *.conf || "$arg1" == *.yaml || "$arg1" == *.yml ]]; then
    config_file="$arg1"; key="${2:-}"
else
    key="$arg1"; config_file="${2:-}"
fi

# ── dso.workflow shim ─────────────────────────────────────────────────────────
# Self-contained resolution for dso.workflow: handles legacy key mapping,
# emits deprecation warnings, and exits before general resolution block.
if [[ "$key" == "dso.workflow" ]]; then
    _wf_config="$config_file"
    if [[ -z "$_wf_config" ]]; then
        if [[ -n "${WORKFLOW_CONFIG_FILE:-}" ]]; then
            _wf_config="${WORKFLOW_CONFIG_FILE}"
        else
            _git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
            [[ -n "$_git_root" && -f "$_git_root/.claude/dso-config.conf" ]] && _wf_config="$_git_root/.claude/dso-config.conf"
        fi
    fi
    if [[ ! -f "${_wf_config:-}" ]]; then
        echo "DSO: No .claude/dso-config.conf found. Run /dso:onboarding to configure dso.workflow." >&2; exit 1
    fi
    _canonical=$(grep -m1 "^dso\.workflow=" "$_wf_config" 2>/dev/null | cut -d= -f2-)
    [[ -n "$_canonical" ]] && { printf '%s\n' "$_canonical"; exit 0; }
    _merge=$(grep -m1 "^merge\.strategy=" "$_wf_config" 2>/dev/null | cut -d= -f2-)
    _enforce=$(grep -m1 "^enforcement\.strategy=" "$_wf_config" 2>/dev/null | cut -d= -f2-)
    # Only emit the legacy-deprecation message when at least one legacy key is
    # actually present; otherwise the user has no legacy keys to deprecate.
    if [[ -n "$_merge" || -n "$_enforce" ]]; then
        [[ -z "${DSO_DEPRECATION_QUIET:-}" ]] && echo "DSO deprecation: merge.strategy/enforcement.strategy are deprecated. Set dso.workflow=ci-pr|local" >&2
    fi
    if [[ "$_merge" == "pr" && "$_enforce" == "ci" ]]; then
        printf '%s' "ci-pr"
    else
        # Bug f6fd-af80-9b13-4649: when the canonical key is missing AND the
        # legacy keys are absent or do not match the required pair, emit a
        # loud warning so callers can diagnose which fallback was taken.
        [[ -z "${DSO_DEPRECATION_QUIET:-}" ]] && echo "DSO WARNING: dso.workflow could not be resolved from $_wf_config (canonical key missing, legacy keys absent or incomplete); defaulting to 'local'" >&2
        printf '%s' "local"
    fi
    exit 0
fi

# ── review.max_cycles shim ───────────────────────────────────────────────────
# Backward-compat: when only the old key review.max_resolution_attempts is set,
# reading review.max_cycles returns that value with a deprecation warning.
# When both keys are set, the new key (review.max_cycles) takes priority.
if [[ "$key" == "review.max_cycles" ]]; then
    _rc_config="$config_file"
    if [[ -z "$_rc_config" ]]; then
        if [[ -n "${WORKFLOW_CONFIG_FILE:-}" ]]; then
            _rc_config="${WORKFLOW_CONFIG_FILE}"
        else
            _git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
            [[ -n "$_git_root" && -f "$_git_root/.claude/dso-config.conf" ]] && _rc_config="$_git_root/.claude/dso-config.conf"
        fi
    fi
    if [[ -f "${_rc_config:-}" ]]; then
        _new_val=$(grep -m1 "^review\.max_cycles=" "$_rc_config" 2>/dev/null | cut -d= -f2-)
        if [[ -n "$_new_val" ]]; then
            printf '%s' "$_new_val"
            exit 0
        fi
        _old_val=$(grep -m1 "^review\.max_resolution_attempts=" "$_rc_config" 2>/dev/null | cut -d= -f2-)
        if [[ -n "$_old_val" ]]; then
            [[ -z "${DSO_DEPRECATION_QUIET:-}" ]] && echo "DSO deprecation: review.max_resolution_attempts is deprecated; rename to review.max_cycles in dso-config.conf" >&2
            printf '%s' "$_old_val"
            exit 0
        fi
    fi
    printf ''
    exit 0
fi

# Sentinel lockout for legacy keys — after migration, any read of a legacy key fails fast.
# IMPORTANT: Do NOT commit .claude/.dso-config-v2-migrated until after S6 legacy-reference
# cleanup is merged. The sentinel file should be gitignored locally during the S3→S6 window.
_legacy_keys="merge.strategy enforcement.strategy worktree.isolation_enabled attribution.enabled"
# shellcheck disable=SC2086  # intentional word-split to print one key per line
if printf '%s\n' $_legacy_keys | grep -qx "$key" 2>/dev/null; then
    _sentinel_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_sentinel_root" && -f "$_sentinel_root/.claude/.dso-config-v2-migrated" ]]; then
        echo "DSO: '$key' is a legacy config key that has been disabled after migration. To restore, run: git checkout HEAD -- .claude/dso-config.conf" >&2
        exit 1
    fi
fi

# Resolve config file when not specified (.conf only)
# Resolution order:
#   1. WORKFLOW_CONFIG_FILE env var (exact file path — highest priority, for test isolation)
#   2. git rev-parse --show-toplevel/.claude/dso-config.conf (new canonical path)
# NOTE: CLAUDE_PLUGIN_ROOT-based resolution removed — CLAUDE_PLUGIN_ROOT points to the plugin
#       dir, not the host project git root. Host projects now always use .claude/dso-config.conf.
if [[ -z "$config_file" ]]; then
    if [[ -n "${WORKFLOW_CONFIG_FILE:-}" ]]; then
        config_file="${WORKFLOW_CONFIG_FILE}"
    else
        _git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$_git_root" && -f "$_git_root/.claude/dso-config.conf" ]]; then
            config_file="$_git_root/.claude/dso-config.conf"
        else
            exit 0
        fi
    fi
fi
# Missing file: exit 0 (graceful degradation)
if [[ ! -f "$config_file" ]]; then
    exit 0
fi

# ── Detect file format ────────────────────────────────────────────────────────
# YAML files (.yaml/.yml) or files whose first non-comment line contains ':'
# but not '=' are parsed with Python; otherwise flat KEY=VALUE.
_is_yaml() {
    if [[ "$config_file" == *.yaml || "$config_file" == *.yml ]]; then
        return 0
    fi
    # Heuristic: if first non-comment, non-empty line has ':' but no '='
    local first_line
    first_line=$(grep -v '^\s*#' "$config_file" | grep -v '^\s*$' | head -1)
    if [[ "$first_line" == *":"* && "$first_line" != *"="* ]]; then
        return 0
    fi
    return 1
}

# ── YAML reader (pure Python, no pyyaml dependency) ─────────────────────────
# Parses simple YAML config files (nested key: value pairs, no anchors/aliases).
_yaml_read_key() {
    local file="$1" dotkey="$2"
    python3 -c "
import sys, re

def parse_simple_yaml(filepath):
    \"\"\"Parse simple YAML into nested dict. Handles key: value and nesting via indentation.\"\"\"
    result = {}
    stack = [(-1, result)]  # (indent_level, current_dict)
    with open(filepath) as f:
        for line in f:
            stripped = line.rstrip()
            if not stripped or stripped.lstrip().startswith('#'):
                continue
            indent = len(line) - len(line.lstrip())
            # Pop stack to find parent at correct indent level
            while len(stack) > 1 and stack[-1][0] >= indent:
                stack.pop()
            parent = stack[-1][1]
            m = re.match(r'^(\s*)([^#:]+?):\s*(.*)', stripped)
            if not m:
                continue
            key = m.group(2).strip()
            value = m.group(3).strip()
            if value:
                # Strip quotes from value
                if (value.startswith('\"') and value.endswith('\"')) or \
                   (value.startswith(\"'\") and value.endswith(\"'\")):
                    value = value[1:-1]
                # Handle booleans
                if value.lower() in ('true', 'yes'):
                    parent[key] = True
                elif value.lower() in ('false', 'no'):
                    parent[key] = False
                else:
                    parent[key] = value
            else:
                # Nested section
                child = {}
                parent[key] = child
                stack.append((indent, child))
    return result

data = parse_simple_yaml(sys.argv[1])
keys = sys.argv[2].split('.')
val = data
for k in keys:
    if isinstance(val, dict) and k in val:
        val = val[k]
    else:
        sys.exit(2)

if isinstance(val, bool):
    print(str(val))
elif val is not None:
    print(str(val))
" "$file" "$dotkey"
}

_yaml_batch() {
    local file="$1"
    python3 -c "
import sys, re

def parse_simple_yaml(filepath):
    result = {}
    stack = [(-1, result)]
    with open(filepath) as f:
        for line in f:
            stripped = line.rstrip()
            if not stripped or stripped.lstrip().startswith('#'):
                continue
            indent = len(line) - len(line.lstrip())
            while len(stack) > 1 and stack[-1][0] >= indent:
                stack.pop()
            parent = stack[-1][1]
            m = re.match(r'^(\s*)([^#:]+?):\s*(.*)', stripped)
            if not m:
                continue
            key = m.group(2).strip()
            value = m.group(3).strip()
            if value:
                if (value.startswith('\"') and value.endswith('\"')) or \
                   (value.startswith(\"'\") and value.endswith(\"'\")):
                    value = value[1:-1]
                if value.lower() in ('true', 'yes'):
                    parent[key] = True
                elif value.lower() in ('false', 'no'):
                    parent[key] = False
                else:
                    parent[key] = value
            else:
                child = {}
                parent[key] = child
                stack.append((indent, child))
    return result

def flatten(d, prefix=''):
    for k, v in d.items():
        full_key = f'{prefix}.{k}' if prefix else k
        if isinstance(v, dict):
            flatten(v, full_key)
        else:
            var_name = full_key.upper().replace('.', '_')
            val = str(v) if v is not None else ''
            safe_val = val.replace(\"'\", \"'\\\\''\" )
            print(f\"{var_name}='{safe_val}'\")

flatten(parse_simple_yaml(sys.argv[1]))
" "$file"
}

if _is_yaml; then
    if [[ -n "$batch_mode" ]]; then
        _yaml_batch "$config_file"
        exit 0
    elif [[ -n "$list_mode" ]]; then
        result=$(_yaml_read_key "$config_file" "$key") || exit 1
        [[ -n "$result" ]] && { printf '%s\n' "$result"; exit 0; }
        exit 1
    else
        result=$(_yaml_read_key "$config_file" "$key" 2>/dev/null) || true
        printf '%s' "$result"
        exit 0
    fi
fi

# ── .conf format: flat KEY=VALUE lines ───────────────────────────────────────
_conf_lines() { grep -v '^\s*#' "$config_file"; }
if [[ -n "$batch_mode" ]]; then
    # Output all keys as UPPER_CASE_WITH_UNDERSCORES=value lines (safe for eval)
    while read -r line; do
        [[ -z "$line" ]] && continue
        raw_key="${line%%=*}"
        raw_val="${line#*=}"
        var_name="${raw_key^^}"        # uppercase
        var_name="${var_name//./_}"    # dots to underscores
        # Single-quote value for safe eval; escape any single quotes in value
        safe_val="${raw_val//\'/\'\\\'\'}"
        printf "%s='%s'\n" "$var_name" "$safe_val"
    done < <(_conf_lines | grep -E '^[^=]+=')
    exit 0
elif [[ -n "$list_mode" ]]; then
    results=$(_conf_lines | grep "^${key}=" | cut -d= -f2-)
    [[ -n "$results" ]] && { printf '%s\n' "$results"; exit 0; }; exit 1
else
    printf '%s' "$(_conf_lines | grep -m1 "^${key}=" | cut -d= -f2-)"; exit 0
fi
