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

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 2
fi
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"

# Source config-paths.sh for portable path resolution
_CONFIG_PATHS="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
if [ -f "$_CONFIG_PATHS" ]; then
    # shellcheck source=../hooks/lib/config-paths.sh
    source "$_CONFIG_PATHS"
fi

phase="${1:-}"
shift || true
SKIP_CI=0
for arg in "$@"; do
    case "$arg" in
        --skip-ci) SKIP_CI=1 ;;
    esac
done
if [ -z "$phase" ]; then
    echo "Usage: validate-phase.sh {auto-fix|post-batch|tier-transition|full} [--skip-ci]"
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
    local default="${2:-}"
    local val
    val=$("$READ_CONFIG" "$key" "$CONFIG_FILE" 2>/dev/null || true)
    if [ -z "$val" ] && [ -n "$default" ]; then
        echo "$default"
    else
        echo "$val"
    fi
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
# format/format_check/lint are optional — polyglot repos may not configure all three.
# Missing keys emit [DSO WARN] and silently skip the relevant steps.
CMD_FORMAT=$(_cfg "commands.format" "")
CMD_FORMAT_CHECK=$(_cfg "commands.format_check" "")
CMD_LINT=$(_cfg "commands.lint" "")
[[ -z "$CMD_FORMAT" ]] && echo "[DSO WARN] commands.format not configured — format steps will be skipped." >&2
[[ -z "$CMD_FORMAT_CHECK" ]] && echo "[DSO WARN] commands.format_check not configured — format check steps will be skipped." >&2
[[ -z "$CMD_LINT" ]] && echo "[DSO WARN] commands.lint not configured — lint steps will be skipped." >&2
CMD_LINT_FIX=$(_cfg "commands.lint_fix" "")  # optional: only used in phase_auto_fix
CMD_TEST_UNIT=$(_cfg "commands.test_unit" "make test-unit-only")
CMD_VALIDATE=$(_cfg_required "commands.validate")

# test-batched.sh integration (mirrors validate.sh pattern for time-bounded execution).
# Override VALIDATE_TEST_BATCHED_SCRIPT in tests to inject a stub.
VALIDATE_TEST_BATCHED_SCRIPT="${VALIDATE_TEST_BATCHED_SCRIPT:-$SCRIPT_DIR/test-batched.sh}"
# Override VALIDATE_TEST_STATE_FILE in tests for isolation.
VALIDATE_TEST_STATE_FILE="${VALIDATE_TEST_STATE_FILE:-/tmp/validate-phase-test-state.json}"
export VALIDATE_TEST_STATE_FILE
export TEST_BATCHED_STATE_FILE="$VALIDATE_TEST_STATE_FILE"

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
    # .claude/dso-config.conf. This file is project-controlled (committed to the repo) and is
    # not user-supplied at runtime. All current config values are simple make targets
    # (e.g., "make lint", "make format-check"). The threat model for a developer-facing
    # toolchain script does not include adversarial config files; a user with write access
    # to .claude/dso-config.conf already has full repo access. eval is required to support
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

# run_test_batched: time-bounded test runner using test-batched.sh.
# When test-batched.sh is available, delegates test execution to it.
# If test-batched.sh outputs "RUN:", sets any_fail_ref=2 (pending).
# Falls back to direct eval when test-batched.sh is not available.
#
# Usage: run_test_batched <any_fail_ref>
#   any_fail_ref — name of the integer variable to set on failure or pending
#
# Outputs a TESTS: PASS / FAIL / PENDING line to stdout.
# Sets $any_fail_ref to 1 on failure, 2 on pending (RUN: detected).
run_test_batched() {
    local -n _any_fail="$1"
    local batched_script="$VALIDATE_TEST_BATCHED_SCRIPT"
    local batched_timeout=65

    if [ -x "$batched_script" ]; then
        local rc=0
        local batched_output
        # Run test-batched.sh; capture stdout+stderr together.
        # test-batched.sh manages its own time budget (--timeout=65).
        batched_output=$(
            TEST_BATCHED_STATE_FILE="$VALIDATE_TEST_STATE_FILE" \
            bash "$batched_script" --timeout="$batched_timeout" "$CMD_TEST_UNIT" 2>&1
        ) || rc=$?

        # Detect partial run: test-batched.sh prints "RUN:" when time budget exhausted.
        # In that case it exits 0, but tests are not done — emit TESTS: PENDING.
        if [ "$rc" = "0" ] && echo "$batched_output" | grep -q "^RUN:"; then
            echo "TESTS: PENDING (run validate-phase.sh again to continue)"
            _any_fail=2
            return
        fi

        if [ "$rc" -eq 0 ]; then
            local passed
            passed=$(echo "$batched_output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1 || echo "?")
            echo "TESTS: PASS ($passed passed, 0 failed)"
        else
            _any_fail=1
            local passed failed failing_names
            passed=$(echo "$batched_output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1 || echo "0")
            failed=$(echo "$batched_output" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | tail -1 || echo "?")
            failing_names=$(echo "$batched_output" | grep -E '^FAILED ' | sed 's/^FAILED //' | tr '\n' ', ' | sed 's/, $//')
            echo "TESTS: FAIL ($passed passed, $failed failed — failed: ${failing_names:-unknown})"
        fi
    else
        # Fallback: test-batched.sh not available — run directly (original behavior)
        local test_output
        if test_output=$(cd "$REPO_ROOT" && eval "$CMD_TEST_UNIT" 2>&1); then
            local passed
            passed=$(echo "$test_output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo "?")
            echo "TESTS: PASS ($passed passed, 0 failed)"
        else
            _any_fail=1
            local passed failed failing_names
            passed=$(echo "$test_output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo "0")
            failed=$(echo "$test_output" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo "?")
            failing_names=$(echo "$test_output" | grep -E '^FAILED ' | sed 's/^FAILED //' | tr '\n' ', ' | sed 's/, $//')
            echo "TESTS: FAIL ($passed passed, $failed failed — failed: ${failing_names:-unknown})"
        fi
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
    if [[ -n "$CMD_FORMAT" ]]; then
        collect_modified "FORMAT" "$CMD_FORMAT"
    fi

    # Tier 1: Lint auto-fix (optional — only runs if commands.lint_fix is configured)
    if [ -n "$CMD_LINT_FIX" ]; then
        collect_modified "LINT" "$CMD_LINT_FIX"
    fi

    # Validate
    if [[ -n "$CMD_FORMAT_CHECK" ]]; then
        run_check "FORMAT_CHECK" "$CMD_FORMAT_CHECK" || any_fail=1
    fi
    if [[ -n "$CMD_LINT" ]]; then
        run_check "LINT" "$CMD_LINT" || any_fail=1
    fi

    run_test_batched any_fail

    rm -f /tmp/.validate-phase-ts
    [ "$any_fail" -eq 2 ] && return 2
    return $any_fail
}

phase_post_batch() {
    local any_fail=0

    # Format first (fixing, not just checking)
    if [[ -n "$CMD_FORMAT" ]]; then
        (cd "$REPO_ROOT" && eval "$CMD_FORMAT" >/dev/null 2>&1) || true
    fi
    if [[ -n "$CMD_FORMAT_CHECK" ]]; then
        run_check "FORMAT" "$CMD_FORMAT_CHECK" || any_fail=1
    fi
    if [[ -n "$CMD_LINT" ]]; then
        run_check "LINT" "$CMD_LINT" || any_fail=1
    fi

    run_test_batched any_fail

    [ "$any_fail" -eq 2 ] && return 2
    return $any_fail
}

phase_tier_transition() {
    local any_fail=0

    if [[ -n "$CMD_FORMAT_CHECK" ]]; then
        run_check "FORMAT" "$CMD_FORMAT_CHECK" || any_fail=1
    fi
    if [[ -n "$CMD_LINT" ]]; then
        run_check "LINT" "$CMD_LINT" || any_fail=1
    fi

    run_test_batched any_fail

    [ "$any_fail" -eq 2 ] && return 2
    return $any_fail
}

phase_full() {
    local any_fail=0

    # Full validation — path resolved from commands.validate in .claude/dso-config.conf
    # When --skip-ci is set, append it to the validate command so CI status is not checked
    # (useful in worktrees where CI runs on main and hasn't received fixes yet).
    local validate_cmd="$CMD_VALIDATE"
    if [ "$SKIP_CI" = "1" ]; then
        validate_cmd="$CMD_VALIDATE --skip-ci"
    fi
    local val_output
    if val_output=$(cd "$REPO_ROOT" && eval "$validate_cmd" 2>&1); then
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

    # Check for remaining open bugs using v3 ticket CLI (list + JSON parse)
    local bugs
    bugs=$("$TICKET_CMD" list 2>/dev/null | python3 -c "
import json, sys
tickets = json.load(sys.stdin)
for t in tickets:
    if t.get('ticket_type') == 'bug' and t.get('status') in ('open', 'in_progress'):
        print(t['ticket_id'] + ' ' + t.get('title', ''))
" || echo "")
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
