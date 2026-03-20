#!/usr/bin/env bash
set -euo pipefail
# validate-phase.sh — Run a specific validation phase and output structured results.
#
# Replaces the near-identical logic in:
#   - debug-everything/prompts/auto-fix.md (auto-fix)
#   - debug-everything/prompts/post-batch-validation.md (post-batch)
#   - debug-everything/prompts/tier-transition-validation.md (tier-transition)
#   - debug-everything/prompts/full-validation.md (full)
#
# Usage:
#   validate-phase.sh auto-fix           # Run formatters + lint auto-fix, then validate
#   validate-phase.sh post-batch         # Format, lint, unit test (report only)
#   validate-phase.sh tier-transition    # Format-check, lint, unit test (report only)
#   validate-phase.sh full               # Full validate.sh + open bugs check
#
# Output: Structured report to stdout. Exit 0 if all pass, 1 if any fail.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."
TK="${TK:-$SCRIPT_DIR/tk}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 2
fi

# Source config-paths.sh for portable path resolution
_CONFIG_PATHS="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
if [ -f "$_CONFIG_PATHS" ]; then
    # shellcheck source=../hooks/lib/config-paths.sh
    source "$_CONFIG_PATHS"
fi

phase="${1:-}"
if [ -z "$phase" ]; then
    echo "Usage: validate-phase.sh {auto-fix|post-batch|tier-transition|full}"
    exit 2
fi

# --- Config-driven command resolution ---
# All commands are read once from .claude/dso-config.conf via read-config.sh.
# This makes the script portable across projects with different toolchains.
# Missing required keys fail fast with a clear error message.

READ_CONFIG="$SCRIPT_DIR/read-config.sh"
CONFIG_FILE="$REPO_ROOT/.claude/dso-config.conf"

_cfg() {
    local key="$1"
    local val
    val=$("$READ_CONFIG" "$key" "$CONFIG_FILE" 2>/dev/null || true)
    echo "$val"
}

_cfg_required() {
    local key="$1"
    local val
    val=$(_cfg "$key")
    if [ -z "$val" ]; then
        echo "ERROR: $key not configured in .claude/dso-config.conf" >&2
        exit 2
    fi
    echo "$val"
}

# Cache all config values at init to avoid repeated YAML parsing overhead.
CMD_FORMAT=$(_cfg_required "commands.format")
CMD_FORMAT_CHECK=$(_cfg_required "commands.format_check")
CMD_LINT=$(_cfg_required "commands.lint")
CMD_LINT_FIX=$(_cfg "commands.lint_fix")  # optional: only used in phase_auto_fix
CMD_TEST_UNIT=$(_cfg_required "commands.test_unit")
CMD_VALIDATE=$(_cfg_required "commands.validate")

# Source directories for collect_modified (from format.source_dirs list)
# Read as newline-separated list, then build find arguments
_source_dirs=()
while IFS= read -r dir; do
    [ -n "$dir" ] && _source_dirs+=("$REPO_ROOT/$dir")
done < <("$READ_CONFIG" --list "format.source_dirs" "$CONFIG_FILE" 2>/dev/null || true)

# File extensions for collect_modified (from format.extensions list)
_extensions=()
while IFS= read -r ext; do
    [ -n "$ext" ] && _extensions+=("$ext")
done < <("$READ_CONFIG" --list "format.extensions" "$CONFIG_FILE" 2>/dev/null || true)

# Default fallbacks if config keys are missing
if [ "${#_source_dirs[@]}" -eq 0 ]; then
    _CFG_APP="${CFG_APP_DIR:-app}"
    _CFG_SRC="${CFG_SRC_DIR:-src}"
    _CFG_TEST="${CFG_TEST_DIR:-tests}"
    _source_dirs=("$REPO_ROOT/$_CFG_APP/$_CFG_SRC" "$REPO_ROOT/$_CFG_APP/$_CFG_TEST")
fi
if [ "${#_extensions[@]}" -eq 0 ]; then
    _extensions=('.py')
fi

# --- Helpers ---

run_check() {
    local label="$1"
    local cmd="$2"
    local output
    # REVIEW-DEFENSE: eval is used here to execute config-supplied command strings from
    # workflow-config.conf. This file is project-controlled (committed to the repo) and is
    # not user-supplied at runtime. All current config values are simple make targets
    # (e.g., "make lint", "make format-check"). The threat model for a developer-facing
    # toolchain script does not include adversarial config files; a user with write access
    # to workflow-config.conf already has full repo access. eval is required to support
    # commands with embedded arguments (e.g., "make target ARGS=value") as single config strings.
    if output=$(cd "$REPO_ROOT" && eval "$cmd" 2>&1); then
        echo "$label: PASS"
        return 0
    else
        # Extract failure count from output if possible
        local violations
        case "$label" in
            LINT)
                # Generic lint failure: attempt to extract a count from the output,
                # falling back gracefully when the output format is unrecognized.
                # Handles ruff-style (file:line:col:), mypy-style (Found N error(s)),
                # eslint-style (N problems), and fully unknown output.
                violations=$(echo "$output" | grep -cE '^\S+:\d+:\d+:' 2>/dev/null || true)
                if [ "${violations:-0}" -gt 0 ] 2>/dev/null; then
                    echo "$label: FAIL ($violations violations)"
                else
                    local mypy_count
                    mypy_count=$(echo "$output" | grep -oE 'Found [0-9]+ error' | grep -oE '[0-9]+' || true)
                    if [ -n "$mypy_count" ]; then
                        echo "$label: FAIL ($mypy_count errors)"
                    else
                        echo "$label: FAIL"
                    fi
                fi
                ;;
            TESTS)
                local passed failed
                passed=$(echo "$output" | grep -oE '\d+ passed' | grep -oE '\d+' || echo "0")
                failed=$(echo "$output" | grep -oE '\d+ failed' | grep -oE '\d+' || echo "?")
                local failing_names
                failing_names=$(echo "$output" | grep -E '^FAILED ' | sed 's/^FAILED //' | tr '\n' ', ' | sed 's/, $//')
                echo "$label: FAIL ($passed passed, $failed failed — failed: ${failing_names:-unknown})"
                ;;
            *)
                echo "$label: FAIL"
                ;;
        esac
        return 1
    fi
}

collect_modified() {
    local label="$1"
    local cmd="$2"
    local before after modified
    # Build find arguments for all configured source dirs and extensions
    # REVIEW-DEFENSE: Literal "(" and ")" as bash array elements are safe on macOS BSD find.
    # When passed via "${find_args[@]}" (quoted array expansion), bash does NOT interpret them
    # as subshell operators — each element is passed as a separate, verbatim argument to find.
    # BSD find (macOS) accepts unescaped "(" and ")" as grouping operators when they arrive
    # as distinct argv entries. This was verified on Darwin 25.x. The concern about shell
    # metacharacter expansion does not apply to array elements passed through "${arr[@]}".
    local find_args=()
    for dir in "${_source_dirs[@]}"; do
        find_args+=("$dir")
    done
    find_args+=("(")
    local first=1
    for ext in "${_extensions[@]}"; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            find_args+=("-o")
        fi
        find_args+=("-name" "*${ext}")
    done
    find_args+=(")")

    before=$(find "${find_args[@]}" -newer /tmp/.validate-phase-ts 2>/dev/null | sort || true)
    touch /tmp/.validate-phase-ts
    (cd "$REPO_ROOT" && eval "$cmd" >/dev/null 2>&1) || true
    after=$(find "${find_args[@]}" -newer /tmp/.validate-phase-ts 2>/dev/null | sort || true)
    modified=$(comm -13 <(echo "$before") <(echo "$after") | xargs -I{} basename {} 2>/dev/null | tr '\n' ', ' | sed 's/, $//')
    echo "${label}_MODIFIED: ${modified:-none}"
}

# --- Phases ---

phase_auto_fix() {
    local any_fail=0
    touch /tmp/.validate-phase-ts

    # Tier 0: Format
    collect_modified "FORMAT" "$CMD_FORMAT"

    # Tier 1: Lint auto-fix (optional — only runs if commands.lint_fix is configured)
    if [ -n "$CMD_LINT_FIX" ]; then
        collect_modified "LINT" "$CMD_LINT_FIX"
    fi

    # Validate
    run_check "FORMAT_CHECK" "$CMD_FORMAT_CHECK" || any_fail=1
    run_check "LINT" "$CMD_LINT" || any_fail=1

    local test_output
    if test_output=$(cd "$REPO_ROOT" && eval "$CMD_TEST_UNIT" 2>&1); then
        local passed
        passed=$(echo "$test_output" | grep -oE '\d+ passed' | grep -oE '\d+' || echo "?")
        echo "TESTS: PASS ($passed passed, 0 failed)"
    else
        any_fail=1
        local passed failed failing_names
        passed=$(echo "$test_output" | grep -oE '\d+ passed' | grep -oE '\d+' || echo "0")
        failed=$(echo "$test_output" | grep -oE '\d+ failed' | grep -oE '\d+' || echo "?")
        failing_names=$(echo "$test_output" | grep -E '^FAILED ' | sed 's/^FAILED //' | tr '\n' ', ' | sed 's/, $//')
        echo "TESTS: FAIL ($passed passed, $failed failed — failed: ${failing_names:-unknown})"
    fi

    rm -f /tmp/.validate-phase-ts
    return $any_fail
}

phase_post_batch() {
    local any_fail=0

    # Format first (fixing, not just checking)
    (cd "$REPO_ROOT" && eval "$CMD_FORMAT" >/dev/null 2>&1) || true
    run_check "FORMAT" "$CMD_FORMAT_CHECK" || any_fail=1
    run_check "LINT" "$CMD_LINT" || any_fail=1

    local test_output
    if test_output=$(cd "$REPO_ROOT" && eval "$CMD_TEST_UNIT" 2>&1); then
        local passed
        passed=$(echo "$test_output" | grep -oE '\d+ passed' | grep -oE '\d+' || echo "?")
        echo "TESTS: PASS ($passed passed, 0 failed)"
    else
        any_fail=1
        local passed failed failing_names
        passed=$(echo "$test_output" | grep -oE '\d+ passed' | grep -oE '\d+' || echo "0")
        failed=$(echo "$test_output" | grep -oE '\d+ failed' | grep -oE '\d+' || echo "?")
        failing_names=$(echo "$test_output" | grep -E '^FAILED ' | sed 's/^FAILED //' | tr '\n' ', ' | sed 's/, $//')
        echo "TESTS: FAIL ($passed passed, $failed failed — failed: ${failing_names:-unknown})"
    fi

    return $any_fail
}

phase_tier_transition() {
    local any_fail=0

    run_check "FORMAT" "$CMD_FORMAT_CHECK" || any_fail=1
    run_check "LINT" "$CMD_LINT" || any_fail=1

    local test_output
    if test_output=$(cd "$REPO_ROOT" && eval "$CMD_TEST_UNIT" 2>&1); then
        local passed
        passed=$(echo "$test_output" | grep -oE '\d+ passed' | grep -oE '\d+' || echo "?")
        echo "TESTS: PASS ($passed passed, 0 failed)"
    else
        any_fail=1
        local passed failed failing_names
        passed=$(echo "$test_output" | grep -oE '\d+ passed' | grep -oE '\d+' || echo "0")
        failed=$(echo "$test_output" | grep -oE '\d+ failed' | grep -oE '\d+' || echo "?")
        failing_names=$(echo "$test_output" | grep -E '^FAILED ' | sed 's/^FAILED //' | tr '\n' ', ' | sed 's/, $//')
        echo "TESTS: FAIL ($passed passed, $failed failed — failed: ${failing_names:-unknown})"
    fi

    return $any_fail
}

phase_full() {
    local any_fail=0

    # Full validation — path resolved from commands.validate in workflow-config.conf
    local val_output
    if val_output=$(cd "$REPO_ROOT" && eval "$CMD_VALIDATE" 2>&1); then
        echo "RESULT: ALL_PASS"
    else
        any_fail=1
        echo "RESULT: SOME_FAIL"
        echo "VALIDATION_FAILURES:"
        # Parse validate.sh output for failure categories
        echo "$val_output" | grep -E '(FAIL|ERROR|failed)' | while IFS= read -r line; do
            echo "  - $line"
        done
    fi

    # Check for remaining open bugs (tk has no query command; grep ready+blocked for bug type)
    local bugs
    bugs=$( { "$TK" ready 2>/dev/null; "$TK" blocked 2>/dev/null; } | grep -i '\[.*bug.*\]' || echo "")
    if [ -n "$bugs" ]; then
        echo "OPEN_BUGS:"
        echo "$bugs" | while IFS= read -r line; do
            echo "  - $line"
        done
    fi

    return $any_fail
}

# --- Main ---

case "$phase" in
    auto-fix)         phase_auto_fix ;;
    post-batch)       phase_post_batch ;;
    tier-transition)  phase_tier_transition ;;
    full)             phase_full ;;
    *)
        echo "Unknown phase: $phase"
        echo "Usage: validate-phase.sh {auto-fix|post-batch|tier-transition|full}"
        exit 2
        ;;
esac
