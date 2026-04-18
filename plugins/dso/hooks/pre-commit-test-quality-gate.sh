#!/usr/bin/env bash
# hook-boundary: enforcement
# hooks/pre-commit-test-quality-gate.sh
# git pre-commit hook: scans staged test files for anti-patterns and blocks
# commits when low-quality patterns are detected.
#
# DESIGN:
#   This hook runs at git pre-commit time. For each staged file matching test
#   patterns (tests/**), it checks for anti-patterns using the configured tool:
#   - semgrep: runs semgrep --config=semgrep-rules/test-anti-patterns.yaml
#   - bash-grep: uses grep-based fallback for high-confidence patterns
#   - disabled: skips all checks
#
# LOGIC (in order):
#   1. Fail-open on timeout (SIGTERM/SIGURG).
#   2. Read test_quality.enabled from dso-config.conf — if false, exit 0.
#   3. Get staged files via git diff --cached --name-only.
#   4. Filter to test files only (tests/**).
#   5. If no test files staged, exit 0.
#   6. Read test_quality.tool from dso-config.conf (default: bash-grep).
#   7. If tool is semgrep and semgrep is installed, run semgrep analysis.
#   8. If tool is semgrep but semgrep is not installed, warn and exit 0.
#   9. If tool is bash-grep (or semgrep unavailable), run grep-based fallback.
#  10. Report findings and exit non-zero if anti-patterns detected.
#
# INSTALL:
#   Registered in .pre-commit-config.yaml as a local hook (pre-commit stage).
#
# ENVIRONMENT:
#   DSO_CONFIG_FILE       — override path to dso-config.conf (used in tests)
#   CLAUDE_PLUGIN_ROOT    — optional; used to locate semgrep rules
#   TEST_QUALITY_TOOL     — override tool selection (used in tests)

set -uo pipefail

# ── Fail-open on timeout ─────────────────────────────────────────────────────
# shellcheck disable=SC2329  # Pre-existing: function invoked indirectly via trap SIGTERM/SIGURG
_fail_open_on_timeout() {
    echo "pre-commit-test-quality-gate: WARNING: timed out — failing open (commit allowed)" >&2
    exit 0
}
trap _fail_open_on_timeout TERM URG

# ── Locate hook and plugin directories ──────────────────────────────────────
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$HOOK_DIR/.." && pwd)}"

# ── Resolve config file ─────────────────────────────────────────────────────
_resolve_quality_config() {
    local config_file=""
    # 1. Explicit override via DSO_CONFIG_FILE
    if [[ -n "${DSO_CONFIG_FILE:-}" && -f "${DSO_CONFIG_FILE}" ]]; then
        config_file="$DSO_CONFIG_FILE"
    fi
    # 2. Standard location relative to repo root
    if [[ -z "$config_file" ]]; then
        local repo_root
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$repo_root" && -f "$repo_root/.claude/dso-config.conf" ]]; then
            config_file="$repo_root/.claude/dso-config.conf"
        fi
    fi
    echo "$config_file"
}

_read_config_value() {
    local config_file="$1" key="$2" default="${3:-}"
    if [[ -n "$config_file" && -f "$config_file" ]]; then
        local val
        val=$(grep "^${key}=" "$config_file" 2>/dev/null | tail -1 | cut -d= -f2- || true)
        if [[ -n "$val" ]]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# ── Read configuration ──────────────────────────────────────────────────────
CONFIG_FILE=$(_resolve_quality_config)
QUALITY_ENABLED=$(_read_config_value "$CONFIG_FILE" "test_quality.enabled" "true")
QUALITY_TOOL="${TEST_QUALITY_TOOL:-$(_read_config_value "$CONFIG_FILE" "test_quality.tool" "bash-grep")}"

# ── Check if gate is disabled ───────────────────────────────────────────────
if [[ "$QUALITY_ENABLED" == "false" ]]; then
    exit 0
fi

# ── Early tool availability check ───────────────────────────────────────────
# Check tool availability before scanning files — emit warning immediately
# so callers can detect graceful degradation even without staged test files.
if [[ "$QUALITY_TOOL" == "semgrep" ]] && ! command -v semgrep >/dev/null 2>&1; then
    echo "pre-commit-test-quality-gate: WARNING: semgrep not found — degraded mode, skipping quality checks" >&2
    exit 0
fi

if [[ "$QUALITY_TOOL" == "disabled" ]]; then
    exit 0
fi

# ── Get staged test files ───────────────────────────────────────────────────
STAGED_TEST_FILES=()
_staged_output=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -n "$_staged_output" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Match files in tests/ directories
        case "$f" in
            tests/*) STAGED_TEST_FILES+=("$f") ;;
        esac
    done <<< "$_staged_output"
fi

# No test files staged → nothing to check
if [[ ${#STAGED_TEST_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# ── Tool selection and execution ─────────────────────────────────────────────
VIOLATIONS_FOUND=0
VIOLATION_DETAILS=""

# --- Semgrep path ---
_run_semgrep() {
    local rules_file="$HOOK_DIR/semgrep-rules/test-anti-patterns.yaml"
    if [[ ! -f "$rules_file" ]]; then
        echo "pre-commit-test-quality-gate: WARNING: semgrep rules not found at $rules_file — skipping" >&2
        return 0
    fi

    local semgrep_output
    # Run semgrep on each staged test file
    semgrep_output=$(semgrep --config="$rules_file" --json "${STAGED_TEST_FILES[@]}" 2>/dev/null) || true

    # Check if semgrep found any results
    if [[ -n "$semgrep_output" ]]; then
        local result_count
        result_count=$(echo "$semgrep_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('results',[])))" 2>/dev/null || echo "0")
        if [[ "$result_count" -gt 0 ]]; then
            VIOLATIONS_FOUND=$result_count
            VIOLATION_DETAILS="semgrep detected $result_count test anti-pattern(s)"
        fi
    fi
}

# --- Bash-grep fallback ---
_run_bash_grep() {
    local file violations=0
    for file in "${STAGED_TEST_FILES[@]}"; do
        # Get the staged content of the file
        local content
        content=$(git show ":${file}" 2>/dev/null || true)
        [[ -z "$content" ]] && continue

        # High-confidence anti-pattern: grep/cat on source files in tests
        # Pattern: grep -q "something" source_file.py
        #          grep -q "something" source.py
        #          cat source_file.py | grep
        if echo "$content" | grep -qE 'grep\s+(-[a-zA-Z]*\s+)*"[^"]*"\s+[a-zA-Z_][a-zA-Z0-9_]*\.(py|sh|js|ts|rb|go|rs|java|c|cpp|h)' 2>/dev/null; then
            (( violations++ ))
            VIOLATION_DETAILS="${VIOLATION_DETAILS:+${VIOLATION_DETAILS}; }${file}: grep on source file detected"
        fi

        # High-confidence anti-pattern: cat source_file | grep
        if echo "$content" | grep -qE 'cat\s+[a-zA-Z_][a-zA-Z0-9_]*\.(py|sh|js|ts|rb|go|rs|java|c|cpp|h)\s*\|' 2>/dev/null; then
            (( violations++ ))
            VIOLATION_DETAILS="${VIOLATION_DETAILS:+${VIOLATION_DETAILS}; }${file}: cat source file | grep detected"
        fi

        # High-confidence anti-pattern: os.path.exists as sole assertion
        if echo "$content" | grep -qE 'assert\s+os\.path\.exists\(' 2>/dev/null; then
            (( violations++ ))
            VIOLATION_DETAILS="${VIOLATION_DETAILS:+${VIOLATION_DETAILS}; }${file}: os.path.exists as sole assertion"
        fi
    done

    VIOLATIONS_FOUND=$violations
}

# ── Execute selected tool ───────────────────────────────────────────────────
case "$QUALITY_TOOL" in
    semgrep)
        # semgrep availability already verified above
        _run_semgrep
        ;;
    bash-grep)
        _run_bash_grep
        ;;
    *)
        echo "pre-commit-test-quality-gate: WARNING: unknown tool '$QUALITY_TOOL' — skipping" >&2
        exit 0
        ;;
esac

# ── Report results ──────────────────────────────────────────────────────────
if [[ "$VIOLATIONS_FOUND" -gt 0 ]]; then
    echo "" >&2
    echo "BLOCKED: test quality gate" >&2
    echo "" >&2
    echo "  Found $VIOLATIONS_FOUND test anti-pattern(s) in staged test files:" >&2
    echo "  $VIOLATION_DETAILS" >&2
    echo "" >&2
    echo "  Tests should verify observable behavior (outputs, side effects, exit codes)," >&2
    echo "  not inspect source code structure. See behavioral-testing-standard.md." >&2
    echo "" >&2
    exit 1
fi

exit 0
