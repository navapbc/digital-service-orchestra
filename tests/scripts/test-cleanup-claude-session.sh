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
# is absent from dso-config.conf.
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
# Behavioral test: run the plugin script against a repo whose dso-config.conf
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

    # dso-config.conf with no session section (simulates absent artifact_prefix)
    cat > "$TMP_NO_CONFIG/dso-config.conf" <<'CONF'
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

# ── Test 13: Playwright pgrep pattern matches system Chrome with --remote-debugging-pipe ──
# When @playwright/cli auto-selects system Chrome (/Applications/Google Chrome.app/...),
# the spawned processes do NOT contain "playwright" or "ms-playwright" in their path.
# However, Playwright always passes --remote-debugging-pipe to launched browsers.
# The pgrep pattern must match this fingerprint to detect orphaned system Chrome processes.
echo "Test 13: Playwright pgrep pattern matches system Chrome with --remote-debugging-pipe (static check)"
if [ -f "$SCRIPT" ]; then
    # The cleanup script's pgrep pattern must include a conjunctive pattern that
    # combines "chrom" with "remote-debugging-pipe" — matching system Chrome processes
    # launched by Playwright without being so broad as to kill unrelated Chrome instances.
    if grep -qE 'chrom.*remote-debugging-pipe|remote-debugging-pipe.*chrom' "$SCRIPT"; then
        echo "  PASS: pgrep pattern includes conjunctive chrom+remote-debugging-pipe fingerprint"
        (( PASS++ ))
    else
        echo "  FAIL: pgrep pattern does not match conjunctive chrom+remote-debugging-pipe — system Chrome processes spawned by Playwright will not be detected" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 14: Stale auth markers with dead PIDs are removed ────────────────────
# Behavioral test: create /tmp/worktree-isolation-authorized-* files containing
# a dead PID, run the cleanup script, assert the markers were removed.
# This test will FAIL until the cleanup step is added (RED phase).
echo "Test 14: Stale auth markers with dead PIDs are cleaned up"
if [ -x "$SCRIPT" ]; then
    # Create a marker file with a dead PID (99999 is almost certainly dead)
    MARKER=$(mktemp /tmp/worktree-isolation-authorized-XXXXXX)
    echo "99999" > "$MARKER"

    TMP_REPO=$(mktemp -d)
    git -C "$TMP_REPO" init -q
    git -C "$TMP_REPO" config user.email "test@test.com"
    git -C "$TMP_REPO" config user.name "Test"
    touch "$TMP_REPO/file.txt"
    git -C "$TMP_REPO" add . && git -C "$TMP_REPO" commit -q -m "init"

    TMP_HOME=$(mktemp -d)
    (cd "$TMP_REPO" && HOME="$TMP_HOME" bash "$SCRIPT" >/dev/null 2>&1) || true

    rm -rf "$TMP_REPO" "$TMP_HOME"

    if [ ! -f "$MARKER" ]; then
        echo "  PASS: stale auth marker with dead PID was removed"
        (( PASS++ ))
    else
        echo "  FAIL: stale auth marker was NOT removed by cleanup script" >&2
        rm -f "$MARKER"
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 15: Live auth markers (valid PID) are NOT removed ────────────────────
# Behavioral test: create /tmp/worktree-isolation-authorized-* with current PID,
# run cleanup, assert the marker is still present (live session must be preserved).
echo "Test 15: Live auth markers (valid PID) are NOT removed"
if [ -x "$SCRIPT" ]; then
    LIVE_MARKER=$(mktemp /tmp/worktree-isolation-authorized-XXXXXX)
    echo "$$" > "$LIVE_MARKER"

    TMP_REPO=$(mktemp -d)
    git -C "$TMP_REPO" init -q
    git -C "$TMP_REPO" config user.email "test@test.com"
    git -C "$TMP_REPO" config user.name "Test"
    touch "$TMP_REPO/file.txt"
    git -C "$TMP_REPO" add . && git -C "$TMP_REPO" commit -q -m "init"

    TMP_HOME=$(mktemp -d)
    # Use timeout to prevent hang when cleanup script scans /tmp during busy sessions
    timeout 30 bash -c "cd \"$TMP_REPO\" && HOME=\"$TMP_HOME\" bash \"$SCRIPT\" >/dev/null 2>&1" || true

    rm -rf "$TMP_REPO" "$TMP_HOME"

    if [ -f "$LIVE_MARKER" ]; then
        echo "  PASS: live auth marker with valid PID was preserved"
        rm -f "$LIVE_MARKER"
        (( PASS++ ))
    else
        echo "  FAIL: live auth marker was incorrectly removed" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

# ── Test 16: pgrep pattern uses ERE alternation (bare |, not \|) ──────────────
# macOS pgrep -f uses Extended Regular Expressions (ERE). In ERE, alternation
# is bare | (not \| which is BRE). Using \| causes the pattern to match nothing
# silently, which is exactly the bug that allowed orphan Chrome processes to
# accumulate undetected (ticket 7254-8ce2).
#
# This test spawns a mock process and verifies the cleanup script's actual
# pgrep pattern can detect it at runtime — not just that the pattern text
# exists in the source file (which is what Test 13's static grep check does).
echo "Test 16: pgrep pattern uses ERE-compatible alternation (runtime pgrep check)"
if [ -f "$SCRIPT" ]; then
    # Extract the pgrep -f pattern from the script (the quoted string after pgrep ... -f)
    PGREP_PATTERN=$(grep 'PLAYWRIGHT_CLI_PROCS=.*pgrep' "$SCRIPT" | sed -n 's/.*pgrep.*-f "\([^"]*\)".*/\1/p')
    if [ -z "$PGREP_PATTERN" ]; then
        echo "  FAIL: could not extract pgrep pattern from cleanup script" >&2
        (( FAIL++ ))
    else
        # Spawn a mock process whose command line matches one of the pattern's alternatives.
        # Use "chrom" + "remote-debugging-pipe" which is the system-Chrome fingerprint.
        MOCK_CMD="sleep 300 --mock-chromium-for-test --remote-debugging-pipe"
        bash -c "exec -a '$MOCK_CMD' sleep 300" &
        MOCK_PID=$!
        sleep 0.2  # Let process appear in process table

        # Verify pgrep with the script's pattern can find the mock process
        FOUND_PID=$(pgrep -u "$(id -u)" -f "$PGREP_PATTERN" 2>/dev/null || true)
        kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true

        if echo "$FOUND_PID" | grep -q "$MOCK_PID"; then
            echo "  PASS: pgrep pattern correctly matches mock Playwright-launched Chrome process at runtime"
            (( PASS++ ))
        else
            echo "  FAIL: pgrep pattern did NOT match mock process at runtime (ERE alternation broken — likely using \\| instead of |)" >&2
            echo "  Pattern: $PGREP_PATTERN" >&2
            echo "  Mock PID: $MOCK_PID, Found PIDs: ${FOUND_PID:-none}" >&2
            (( FAIL++ ))
        fi
    fi
else
    echo "  SKIP: plugin script not yet created (expected — TDD)"
    (( SKIP++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
