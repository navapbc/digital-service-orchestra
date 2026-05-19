#!/usr/bin/env bash
# ${CLAUDE_PLUGIN_ROOT}/scripts/flag-deprecation-check.sh
# Flag-mint gate: refuses new is_*_enabled() feature flags without a deprecation plan.
#
# Usage:
#   echo "<diff>" | bash flag-deprecation-check.sh [--plan-dir <dir>]
#   bash flag-deprecation-check.sh --diff-file <path> [--plan-dir <dir>]
#
# Arguments:
#   --diff-file <path>  Read diff from file instead of stdin.
#   --plan-dir  <path>  Override directory to search for deprecation plan docs.
#                       Default: $REPO_ROOT/docs/flag-deprecation-plans
#
# Environment:
#   REPO_ROOT   Project root (used to locate default plan-dir). When unset,
#               resolved via git rev-parse --show-toplevel.
#
# Exit codes:
#   0  All new flags have valid deprecation plans (or no new flags found).
#   1  A new flag is missing a plan doc, or an existing plan doc is invalid.
#
# Error format (stderr, exit 1):
#   {"error":"missing_deprecation_plan","flag":"<name>","reason":"<detail>"}
#   {"error":"invalid_deprecation_plan","flag":"<name>","reason":"<detail>"}

set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────

_diff_file=""
_plan_dir_override=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --diff-file)
            _diff_file="$2"
            shift 2
            ;;
        --plan-dir)
            _plan_dir_override="$2"
            shift 2
            ;;
        *)
            echo "flag-deprecation-check.sh: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Resolve REPO_ROOT ─────────────────────────────────────────────────────────

if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo '{"error":"no_repo_root","flag":"","reason":"cannot determine REPO_ROOT"}' >&2
        exit 1
    }
fi

# ── Resolve plan directory ────────────────────────────────────────────────────

if [[ -n "$_plan_dir_override" ]]; then
    _plan_dir="$_plan_dir_override"
else
    _plan_dir="$REPO_ROOT/docs/flag-deprecation-plans"
fi

# ── Read diff ─────────────────────────────────────────────────────────────────

if [[ -n "$_diff_file" ]]; then
    if [[ ! -f "$_diff_file" ]]; then
        echo '{"error":"diff_file_not_found","flag":"","reason":"'"$_diff_file"' does not exist"}' >&2
        exit 1
    fi
    _diff_content="$(cat "$_diff_file")"
else
    _diff_content="$(cat -)"
fi

# ── Detect new is_*_enabled() function additions ──────────────────────────────
# Only match lines starting with '+' (additions), not '++' (diff headers).
# Pattern: ^+[^+].*is_<name>_enabled\s*()

_new_flags=()
while IFS= read -r _line; do
    # Skip diff header lines (+++/---)
    [[ "$_line" =~ ^\+\+\+ ]] && continue
    # Match added lines containing an is_*_enabled() function definition
    if [[ "$_line" =~ ^\+.*is_([a-zA-Z0-9_]+)_enabled[[:space:]]*\(\) ]]; then
        _flag_name="is_${BASH_REMATCH[1]}_enabled"
        _new_flags+=("$_flag_name")
    fi
done <<< "$_diff_content"

# No new flags — all clear.
if [[ ${#_new_flags[@]} -eq 0 ]]; then
    exit 0
fi

# ── Validate each new flag has a deprecation plan ────────────────────────────

_exit_code=0

for _flag in "${_new_flags[@]}"; do
    _plan_file="$_plan_dir/${_flag}.md"

    # Check plan doc exists
    if [[ ! -f "$_plan_file" ]]; then
        printf '{"error":"missing_deprecation_plan","flag":"%s","reason":"no plan doc at docs/flag-deprecation-plans/%s.md"}\n' \
            "$_flag" "$_flag" >&2
        _exit_code=1
        continue
    fi

    # Validate required fields: plan_date, owner, replacement_key.
    # Each field must appear as a key: value assignment (colon-separated).
    _plan_content="$(cat "$_plan_file")"
    _missing_fields=()

    if ! grep -qi "plan_date[[:space:]]*:" <<< "$_plan_content"; then
        _missing_fields+=("plan_date")
    fi
    if ! grep -qi "owner[[:space:]]*:" <<< "$_plan_content"; then
        _missing_fields+=("owner")
    fi
    if ! grep -qi "replacement_key[[:space:]]*:" <<< "$_plan_content"; then
        _missing_fields+=("replacement_key")
    fi

    if [[ ${#_missing_fields[@]} -gt 0 ]]; then
        _missing_list="${_missing_fields[*]}"
        printf '{"error":"invalid_deprecation_plan","flag":"%s","reason":"plan doc missing required fields: %s"}\n' \
            "$_flag" "$_missing_list" >&2
        _exit_code=1
    fi
done

exit "$_exit_code"
