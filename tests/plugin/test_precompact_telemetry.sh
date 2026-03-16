#!/usr/bin/env bash
# tests/plugin/test_precompact_telemetry.sh
#
# Tests for JSONL telemetry writer in pre-compact-checkpoint.sh.
#
# Usage: bash tests/plugin/test_precompact_telemetry.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
COMPACT_HOOK="$REPO_ROOT/lockpick-workflow/hooks/pre-compact-checkpoint.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected='$expected', actual='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local desc="$1"
    shift
    if "$@" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local desc="$1"
    shift
    if "$@" 2>/dev/null; then
        echo "  FAIL: $desc (expected failure but succeeded)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# ── Helper: set up a minimal git repo for hook execution ─────────────────────
setup_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    git init -q -b main "$REALENV/repo"
    git -C "$REALENV/repo" config user.email "test@test.com"
    git -C "$REALENV/repo" config user.name "Test"
    echo "initial" > "$REALENV/repo/README.md"
    git -C "$REALENV/repo" add -A
    git -C "$REALENV/repo" commit -q -m "init"

    echo "$REALENV"
}

# ── Helper: run the hook in a test repo with controlled env ──────────────────
run_hook_in_repo() {
    local repo_dir="$1"
    local fake_home="$2"
    shift 2
    # Additional env vars can be passed as KEY=VALUE pairs
    (
        cd "$repo_dir"
        # Create a dirty file so the hook has "real changes"
        echo "change" > testfile.txt
        env \
            HOME="$fake_home" \
            CLAUDE_SESSION_ID="test-session-123" \
            CLAUDE_PARENT_SESSION_ID="parent-456" \
            CLAUDE_CONTEXT_WINDOW_TOKENS="50000" \
            CLAUDE_CONTEXT_WINDOW_LIMIT="200000" \
            "$@" \
            bash "$COMPACT_HOOK" 2>/dev/null || true
    )
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 1: Telemetry writes JSONL on hook invocation
# ═══════════════════════════════════════════════════════════════════════════════
echo "TEST 1: test_precompact_telemetry_writes_jsonl"

TESTENV=$(setup_test_repo)
REPO_DIR="$TESTENV/repo"
# Create a fake HOME with .claude dir for telemetry
FAKE_HOME="$TESTENV/fakehome"
mkdir -p "$FAKE_HOME/.claude"
TELEMETRY_FILE="$FAKE_HOME/.claude/precompact-telemetry.jsonl"

# Remove any dedup lock files that might interfere
rm -f "${TMPDIR:-/tmp}"/.precompact-lock-*

run_hook_in_repo "$REPO_DIR" "$FAKE_HOME"

assert_true "JSONL telemetry file was created" test -f "$TELEMETRY_FILE"

if [[ -f "$TELEMETRY_FILE" ]]; then
    LINE=$(tail -1 "$TELEMETRY_FILE")

    # Check all 11 required fields are present
    REQUIRED_FIELDS="timestamp session_id parent_session_id context_tokens context_limit active_task_count git_dirty hook_outcome exit_reason working_directory duration_ms"
    for field in $REQUIRED_FIELDS; do
        assert_true "JSONL contains field: $field" grep -q "\"$field\"" "$TELEMETRY_FILE"
    done

    # Validate specific values
    assert_true "session_id is test-session-123" grep -q '"session_id":"test-session-123"' "$TELEMETRY_FILE"
    assert_true "parent_session_id is parent-456" grep -q '"parent_session_id":"parent-456"' "$TELEMETRY_FILE"
    assert_true "context_tokens is 50000" grep -q '"context_tokens":50000' "$TELEMETRY_FILE"
    assert_true "context_limit is 200000" grep -q '"context_limit":200000' "$TELEMETRY_FILE"
    # After commit, working tree is clean — git_dirty reflects state at telemetry write time
    assert_true "git_dirty is false (post-commit)" grep -q '"git_dirty":false' "$TELEMETRY_FILE"
    assert_true "timestamp is ISO 8601" grep -qE '"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$TELEMETRY_FILE"
    assert_true "duration_ms is a non-negative integer" grep -qE '"duration_ms":[0-9]+' "$TELEMETRY_FILE"
    assert_true "working_directory is absolute path" grep -qE '"working_directory":"/' "$TELEMETRY_FILE"
fi

rm -rf "$TESTENV"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 2: Telemetry records early exits (env_var_disabled)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 2: test_precompact_telemetry_early_exit_env_var"

TESTENV=$(setup_test_repo)
REPO_DIR="$TESTENV/repo"
FAKE_HOME="$TESTENV/fakehome"
mkdir -p "$FAKE_HOME/.claude"
TELEMETRY_FILE="$FAKE_HOME/.claude/precompact-telemetry.jsonl"

# Remove any dedup lock files that might interfere
rm -f "${TMPDIR:-/tmp}"/.precompact-lock-*

(
    cd "$REPO_DIR"
    env \
        HOME="$FAKE_HOME" \
        LOCKPICK_DISABLE_PRECOMPACT=1 \
        CLAUDE_SESSION_ID="disabled-session" \
        bash "$COMPACT_HOOK" 2>/dev/null || true
)

assert_true "JSONL file created even on early exit" test -f "$TELEMETRY_FILE"

if [[ -f "$TELEMETRY_FILE" ]]; then
    LINE=$(tail -1 "$TELEMETRY_FILE")
    assert_true "exit_reason is env_var_disabled" grep -q '"exit_reason":"env_var_disabled"' "$TELEMETRY_FILE"
    assert_true "hook_outcome is exited_early" grep -q '"hook_outcome":"exited_early"' "$TELEMETRY_FILE"
fi

rm -rf "$TESTENV"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 3: Telemetry records no_real_changes exit
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 3: test_precompact_telemetry_no_real_changes"

TESTENV=$(setup_test_repo)
REPO_DIR="$TESTENV/repo"
FAKE_HOME="$TESTENV/fakehome"
mkdir -p "$FAKE_HOME/.claude"
TELEMETRY_FILE="$FAKE_HOME/.claude/precompact-telemetry.jsonl"

# Remove any dedup lock files that might interfere
rm -f "${TMPDIR:-/tmp}"/.precompact-lock-*

(
    cd "$REPO_DIR"
    # Clean repo — no uncommitted changes
    env \
        HOME="$FAKE_HOME" \
        CLAUDE_SESSION_ID="clean-session" \
        bash "$COMPACT_HOOK" 2>/dev/null || true
)

assert_true "JSONL file created for no-changes exit" test -f "$TELEMETRY_FILE"

if [[ -f "$TELEMETRY_FILE" ]]; then
    LINE=$(tail -1 "$TELEMETRY_FILE")
    assert_true "exit_reason is no_real_changes" grep -q '"exit_reason":"no_real_changes"' "$TELEMETRY_FILE"
    assert_true "hook_outcome is skipped" grep -q '"hook_outcome":"skipped"' "$TELEMETRY_FILE"
fi

rm -rf "$TESTENV"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 4: Telemetry overhead is under 100ms
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 4: test_precompact_telemetry_overhead"

TESTENV=$(setup_test_repo)
REPO_DIR="$TESTENV/repo"
FAKE_HOME="$TESTENV/fakehome"
mkdir -p "$FAKE_HOME/.claude"
TELEMETRY_FILE="$FAKE_HOME/.claude/precompact-telemetry.jsonl"

# Remove any dedup lock files
rm -f "${TMPDIR:-/tmp}"/.precompact-lock-*

# Use env_var_disabled for fastest exit — measures pure telemetry overhead
(
    cd "$REPO_DIR"
    env \
        HOME="$FAKE_HOME" \
        LOCKPICK_DISABLE_PRECOMPACT=1 \
        CLAUDE_SESSION_ID="overhead-test" \
        bash "$COMPACT_HOOK" 2>/dev/null || true
)

if [[ -f "$TELEMETRY_FILE" ]]; then
    LINE=$(tail -1 "$TELEMETRY_FILE")
    DURATION=$(echo "$LINE" | grep -oE '"duration_ms":[0-9]+' | grep -oE '[0-9]+$')
    if [[ -n "$DURATION" && "$DURATION" -lt 100 ]]; then
        echo "  PASS: duration_ms=$DURATION < 100ms"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: duration_ms=$DURATION >= 100ms (or not found)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  FAIL: telemetry file not found for overhead test"
    FAIL=$((FAIL + 1))
fi

rm -rf "$TESTENV"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 5: Null/unknown values when env vars not set
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 5: test_precompact_telemetry_missing_env_vars"

TESTENV=$(setup_test_repo)
REPO_DIR="$TESTENV/repo"
FAKE_HOME="$TESTENV/fakehome"
mkdir -p "$FAKE_HOME/.claude"
TELEMETRY_FILE="$FAKE_HOME/.claude/precompact-telemetry.jsonl"

rm -f "${TMPDIR:-/tmp}"/.precompact-lock-*

(
    cd "$REPO_DIR"
    # Use env -i for a clean environment, adding back only what's needed
    env -i \
        HOME="$FAKE_HOME" \
        PATH="$PATH" \
        TMPDIR="${TMPDIR:-/tmp}" \
        LOCKPICK_DISABLE_PRECOMPACT=1 \
        bash "$COMPACT_HOOK" 2>/dev/null || true
)

if [[ -f "$TELEMETRY_FILE" ]]; then
    LINE=$(tail -1 "$TELEMETRY_FILE")
    assert_true "session_id defaults to 'unknown'" grep -q '"session_id":"unknown"' "$TELEMETRY_FILE"
    assert_true "parent_session_id is null when unset" grep -q '"parent_session_id":null' "$TELEMETRY_FILE"
    assert_true "context_tokens is null when unset" grep -q '"context_tokens":null' "$TELEMETRY_FILE"
    assert_true "context_limit is null when unset" grep -q '"context_limit":null' "$TELEMETRY_FILE"
else
    echo "  FAIL: telemetry file not found"
    FAIL=$((FAIL + 1))
fi

rm -rf "$TESTENV"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
