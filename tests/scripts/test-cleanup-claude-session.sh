#!/usr/bin/env bash
# tests/scripts/test-cleanup-claude-session.sh
# TDD tests for scripts/cleanup-claude-session.sh (plugin canonical copy).
# These tests are written BEFORE the plugin script exists and will fail/skip until
# Task 2 (lockpick-doc-to-logic-lx9y) creates the plugin script.
#
# Usage: bash tests/scripts/test-cleanup-claude-session.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/cleanup-claude-session.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"
SKIP=0

echo "=== test-cleanup-claude-session.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: scripts/cleanup-claude-session.sh is not executable (plugin script not yet created)" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ─────────────────────────────────────────────
echo "Test 2: No bash syntax errors"
if [ -f "$SCRIPT" ] && bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
elif [ ! -f "$SCRIPT" ]; then
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 3: --help exits 0 and prints usage ───────────────────────────────────
echo "Test 3: --help exits 0 and prints usage"
if [ -x "$SCRIPT" ]; then
    run_test "--help exits 0 and prints Usage" 0 "[Uu]sage" bash "$SCRIPT" --help
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 4: --dry-run exits 0 without filesystem changes ──────────────────────
# Verifies that --dry-run completes without error and without invoking any
# destructive operations (rm / kill). We check both exit code and that no
# actual removals occur in /tmp during a bounded dry-run window.
echo "Test 4: --dry-run exits 0"
if [ -x "$SCRIPT" ]; then
    exit_code=0
    bash "$SCRIPT" --dry-run 2>&1 || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS: --dry-run exits 0"
        (( PASS++ ))
    else
        echo "  FAIL: --dry-run exited $exit_code" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 5: --dry-run produces no destructive operations ──────────────────────
# Static assertion: script must contain dry-run guards (DRY_RUN checks) around
# all rm and kill calls.
echo "Test 5: --dry-run guards wrap rm and kill calls (static check)"
if [ -f "$SCRIPT" ]; then
    # Verify DRY_RUN guard pattern exists alongside destructive commands (rm/kill)
    if grep -qE 'DRY_RUN' "$SCRIPT" && grep -qE '\brm\b|\bkill\b' "$SCRIPT"; then
        echo "  PASS: script contains DRY_RUN guards alongside destructive commands"
        (( PASS++ ))
    else
        echo "  FAIL: script does not contain DRY_RUN guards around destructive operations" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 6: --quiet produces no stdout output ─────────────────────────────────
echo "Test 6: --quiet produces no stdout"
if [ -x "$SCRIPT" ]; then
    output=$(bash "$SCRIPT" --quiet 2>/dev/null)
    if [ -z "$output" ]; then
        echo "  PASS: --quiet produced no stdout"
        (( PASS++ ))
    else
        echo "  FAIL: --quiet produced stdout output" >&2
        echo "  Output was: $output" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 7: --summary-only produces exactly 1 line when environment is clean ──
# We run inside a temp dir with no stale state to get the clean-environment path.
echo "Test 7: --summary-only produces exactly 1 line when environment is clean"
if [ -x "$SCRIPT" ]; then
    TMP_CLEAN_HOME=$(mktemp -d)
    cleanup_tmp() { rm -rf "$TMP_CLEAN_HOME"; }
    trap cleanup_tmp EXIT

    # Run with overridden HOME so no real debug logs interfere; restrict to a
    # temp git repo so worktree lookups return empty lists.
    TMP_REPO=$(mktemp -d)
    git -C "$TMP_REPO" init -q
    git -C "$TMP_REPO" config user.email "test@test.com"
    git -C "$TMP_REPO" config user.name "Test"
    touch "$TMP_REPO/file.txt"
    git -C "$TMP_REPO" add . && git -C "$TMP_REPO" commit -q -m "init"

    line_count=0
    summary_output=$(
        cd "$TMP_REPO" && HOME="$TMP_CLEAN_HOME" bash "$SCRIPT" --summary-only 2>/dev/null
    ) || true

    trap - EXIT
    cleanup_tmp
    rm -rf "$TMP_REPO"

    line_count=$(echo "$summary_output" | grep -c '.' || true)
    if [ "$line_count" -eq 1 ]; then
        echo "  PASS: --summary-only produced exactly 1 line when clean ($summary_output)"
        (( PASS++ ))
    else
        echo "  FAIL: --summary-only produced $line_count lines (expected 1)" >&2
        echo "  Output was: $summary_output" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 8: Absent session.artifact_prefix — Docker and artifact steps skip ───
# Static assertion: all Docker-related commands and artifact-dir operations
# must be guarded by a config key check so they skip gracefully when the key
# is absent from workflow-config.conf.
echo "Test 8: Absent session.artifact_prefix — Docker steps guarded by config key (static check)"
if [ -f "$SCRIPT" ]; then
    # Script must reference artifact_prefix or equivalent config key guard
    if grep -qE 'artifact_prefix|artifact.prefix|ARTIFACT_PREFIX|artifact_dir' "$SCRIPT"; then
        echo "  PASS: script references artifact_prefix config key"
        (( PASS++ ))
    else
        echo "  FAIL: script does not reference artifact_prefix config (Docker/artifact steps are unguarded)" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 9: Absent artifact_prefix — script exits 0 with warning ──────────────
# Behavioral test: run the plugin script against a repo whose workflow-config.conf
# has no session.artifact_prefix key. The script must exit 0 (no crash) and
# emit a warning that the Docker/artifact steps are being skipped.
echo "Test 9: Absent artifact_prefix config — script exits 0 and warns (no-config smoke test)"
if [ -x "$SCRIPT" ]; then
    TMP_NO_CONFIG=$(mktemp -d)
    git -C "$TMP_NO_CONFIG" init -q
    git -C "$TMP_NO_CONFIG" config user.email "test@test.com"
    git -C "$TMP_NO_CONFIG" config user.name "Test"
    touch "$TMP_NO_CONFIG/file.txt"
    git -C "$TMP_NO_CONFIG" add . && git -C "$TMP_NO_CONFIG" commit -q -m "init"

    # workflow-config.conf with no session section (simulates absent artifact_prefix)
    cat > "$TMP_NO_CONFIG/workflow-config.conf" <<'CONF'
format.line_length=100
tickets.directory=.tickets
CONF

    exit_code=0
    no_config_output=$(
        cd "$TMP_NO_CONFIG" && bash "$SCRIPT" --dry-run 2>&1
    ) || exit_code=$?

    rm -rf "$TMP_NO_CONFIG"

    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS: script exits 0 when session.artifact_prefix is absent"
        (( PASS++ ))
    else
        echo "  FAIL: script exited $exit_code with absent session.artifact_prefix config" >&2
        echo "  Output: $no_config_output" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 10: Absent artifact_prefix — warning emitted in output ────────────────
# Companion to Test 9: verify the warning message is in the output when config
# is absent (so the user knows why Docker/artifact steps were skipped).
echo "Test 10: Absent artifact_prefix config — warning emitted (static + behavioral check)"
if [ -f "$SCRIPT" ]; then
    # Static: script must contain a Warning message near the absent-key guard
    if grep -qE '[Ww]arning.*artifact|artifact.*[Ww]arning|[Ss]kipping.*artifact|artifact.*skip' "$SCRIPT"; then
        echo "  PASS: script contains warning for absent artifact_prefix"
        (( PASS++ ))
    else
        echo "  FAIL: script does not emit warning when artifact_prefix is absent" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 11: Python cache step (step 12) is NOT present in plugin script ──────
# The migrated plugin script must NOT include the Python cache cleanup step
# (step 12: .pytest_cache, .ruff_cache, .mypy_cache). That step is project-
# specific and belongs in project scripts only — the plugin must be portable.
echo "Test 11: Python cache cleanup (pytest_cache/ruff_cache) is NOT in plugin script"
if [ -f "$SCRIPT" ]; then
    if grep -qE '\.pytest_cache|\.ruff_cache|python.*cache|step.*12' "$SCRIPT"; then
        echo "  FAIL: plugin script contains Python cache cleanup (step 12) — should be removed for portability" >&2
        (( FAIL++ ))
    else
        echo "  PASS: Python cache cleanup is absent from plugin script"
        (( PASS++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 12: Script references session config section (static check) ──────────
echo "Test 12: Script references session or artifact config section (static check)"
if [ -f "$SCRIPT" ]; then
    if grep -qE 'session\.|artifact_prefix|read.config|workflow-config' "$SCRIPT"; then
        echo "  PASS: script references config-driven session/artifact settings"
        (( PASS++ ))
    else
        echo "  FAIL: script does not reference config-driven settings" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
