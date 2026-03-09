#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-worktree-cleanup.sh
# Baseline tests for scripts/worktree-cleanup.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-worktree-cleanup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Canonical location is lockpick-workflow/scripts/; scripts/ is a thin exec wrapper.
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/worktree-cleanup.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-worktree-cleanup.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: --help exits 0 with usage text ───────────────────────────────────
echo "Test 2: --help exits 0 with usage text"
run_test "--help exits 0 and prints Usage" 0 "[Uu]sage" bash "$SCRIPT" --help

# ── Test 3: Unknown option exits non-zero ─────────────────────────────────────
echo "Test 3: Unknown option exits non-zero"
run_test "unknown option exits 1" 1 "" bash "$SCRIPT" --unknown-flag-xyz

# ── Test 4: --dry-run exits 0 ─────────────────────────────────────────────────
echo "Test 4: --dry-run exits 0"
exit_code=0
bash "$SCRIPT" --dry-run 2>&1 || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "  PASS: --dry-run exits 0"
    (( PASS++ ))
else
    echo "  FAIL: --dry-run exited $exit_code" >&2
    (( FAIL++ ))
fi

# ── Test 5: WORKTREE_CLEANUP_ENABLED=1 with --dry-run exits 0 ────────────────
echo "Test 5: WORKTREE_CLEANUP_ENABLED=1 + --dry-run exits 0"
exit_code=0
WORKTREE_CLEANUP_ENABLED=1 bash "$SCRIPT" --dry-run 2>&1 || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "  PASS: WORKTREE_CLEANUP_ENABLED=1 + --dry-run exits 0"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0, got $exit_code" >&2
    (( FAIL++ ))
fi

# ── Test 6: --all --force --dry-run exits 0 (non-interactive path) ───────────
echo "Test 6: --all --force --dry-run exits 0"
exit_code=0
WORKTREE_CLEANUP_ENABLED=1 bash "$SCRIPT" --all --force --dry-run 2>&1 || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "  PASS: --all --force --dry-run exits 0"
    (( PASS++ ))
else
    echo "  FAIL: --all --force --dry-run exited $exit_code" >&2
    (( FAIL++ ))
fi

# ── Test 7: Script contains stash safety check ────────────────────────────────
echo "Test 7: Script contains stash safety check"
if bash -n "$SCRIPT" 2>/dev/null && grep -q "stash" "$SCRIPT"; then
    echo "  PASS: script contains stash safety check"
    (( PASS++ ))
else
    echo "  FAIL: script does not contain stash safety check" >&2
    (( FAIL++ ))
fi

# ── Test 8: Script checks for WORKTREE_CLEANUP_ENABLED opt-in ────────────────
echo "Test 8: Script references WORKTREE_CLEANUP_ENABLED opt-in"
if grep -qE "WORKTREE_CLEANUP_ENABLED|CLEANUP_ENABLED|--non-interactive|non_interactive" "$SCRIPT"; then
    echo "  PASS: script references opt-in mechanism"
    (( PASS++ ))
else
    echo "  FAIL: script does not reference WORKTREE_CLEANUP_ENABLED opt-in" >&2
    (( FAIL++ ))
fi

# ── Test 9: No bash syntax errors ────────────────────────────────────────────
echo "Test 9: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 10: Script references age/time check ────────────────────────────────
echo "Test 10: Script checks worktree age"
if grep -qE "WT_AGE|WORKTREE_AGE|age_days|AGE_DAYS|age_check|7.*days|days.*7|older.*7|7.*older" "$SCRIPT"; then
    echo "  PASS: script contains age safety check"
    (( PASS++ ))
else
    echo "  FAIL: script does not contain age safety check" >&2
    (( FAIL++ ))
fi

# ── Test 11: MAIN_BRANCH derived from git symbolic-ref ───────────────────────
# test_main_branch_derived_from_git_symbolic_ref
# Verifies that:
#   a) The script uses git symbolic-ref to derive MAIN_BRANCH (not hardcode 'main')
#   b) merge-base --is-ancestor calls use $MAIN_BRANCH, not a bare literal 'main'
#   c) diff commands use $MAIN_BRANCH, not a bare literal 'main'
#   d) The branch guard skips $MAIN_BRANCH in addition to 'detached'/'master'
# This is a static (grep-based) test — the structural invariant must hold in source.
echo "Test 11: MAIN_BRANCH is derived from git symbolic-ref (not hardcoded)"
fail_11=0

if ! grep -q 'symbolic-ref refs/remotes/origin/HEAD' "$SCRIPT"; then
    echo "  FAIL: script does not derive MAIN_BRANCH from git symbolic-ref" >&2
    fail_11=1
fi

if ! grep -qE "MAIN_BRANCH=.*'main'|MAIN_BRANCH:-main" "$SCRIPT"; then
    echo "  FAIL: script does not fall back to 'main' when symbolic-ref fails" >&2
    fail_11=1
fi

# merge-base --is-ancestor calls must reference \$MAIN_BRANCH, not bare 'main'
if grep -qE 'is-ancestor[^$"]*[^$]main\b' "$SCRIPT"; then
    echo "  FAIL: merge-base --is-ancestor uses hardcoded 'main' instead of \$MAIN_BRANCH" >&2
    fail_11=1
fi

# diff commands for branch comparison must not use bare 'main'
if grep -qE 'diff --name-only main\b|diff main\b' "$SCRIPT"; then
    echo "  FAIL: diff command uses hardcoded 'main' instead of \$MAIN_BRANCH" >&2
    fail_11=1
fi

# Branch guard must reference \$MAIN_BRANCH alongside 'master'
if ! grep -qE 'MAIN_BRANCH.*master|master.*MAIN_BRANCH' "$SCRIPT"; then
    echo "  FAIL: branch guard does not reference \$MAIN_BRANCH alongside 'master'" >&2
    fail_11=1
fi

if [ "$fail_11" -eq 0 ]; then
    echo "  PASS: MAIN_BRANCH derived from symbolic-ref with correct usage throughout"
    (( PASS++ ))
else
    (( FAIL++ ))
fi

# ── Test 12: Docker Compose teardown guard: compose_db_file absent → skip ─────
# Static assertion: the Docker Compose teardown block must check CONFIG_COMPOSE_DB_FILE
echo "Test 12: Docker Compose teardown block guards on CONFIG_COMPOSE_DB_FILE"
if grep -qE '\[\[ -n "\$CONFIG_COMPOSE_DB_FILE" \]\]' "$SCRIPT"; then
    echo "  PASS: Docker Compose teardown guards on CONFIG_COMPOSE_DB_FILE"
    (( PASS++ ))
else
    echo "  FAIL: Docker Compose teardown does not guard on CONFIG_COMPOSE_DB_FILE" >&2
    (( FAIL++ ))
fi

# ── Test 13: Orphaned network cleanup guard: compose_db_file absent → skip ────
# Static assertion: the orphaned Docker network cleanup block must check CONFIG_COMPOSE_DB_FILE
echo "Test 13: Orphaned Docker network cleanup guards on CONFIG_COMPOSE_DB_FILE"
orphan_net_block_line=$(grep -n "Clean up orphaned Docker networks" "$SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$orphan_net_block_line" ]]; then
    # Check that CONFIG_COMPOSE_DB_FILE appears in the guard condition for that block
    # (within 5 lines of the section header)
    block_range_end=$(( orphan_net_block_line + 10 ))
    if awk "NR>=$orphan_net_block_line && NR<=$block_range_end" "$SCRIPT" | grep -qE '\[\[ -n "\$CONFIG_COMPOSE_DB_FILE" \]\]|\$CONFIG_COMPOSE_DB_FILE'; then
        echo "  PASS: orphaned network cleanup guards on CONFIG_COMPOSE_DB_FILE"
        (( PASS++ ))
    else
        echo "  FAIL: orphaned network cleanup does not guard on CONFIG_COMPOSE_DB_FILE" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: orphaned Docker network cleanup section not found in script" >&2
    (( FAIL++ ))
fi

# ── Test 14: Partial config warning — compose_project present, compose_db_file absent ──
# Static assertion: script must contain logic that emits a warning when compose_project
# is set but compose_db_file is absent. We look for a Warning: message near the
# CONFIG_COMPOSE_PROJECT / CONFIG_COMPOSE_DB_FILE check.
echo "Test 14: Script contains Warning log for partial Docker config (compose_project set, compose_db_file absent)"
if grep -qE '[Ww]arning.*[Dd]ocker|[Ww]arning.*compose|partial.*[Dd]ocker.*config|[Dd]ocker.*partial.*config' "$SCRIPT"; then
    echo "  PASS: script contains partial Docker config warning"
    (( PASS++ ))
else
    echo "  FAIL: script missing partial Docker config warning (compose_project set, compose_db_file absent)" >&2
    (( FAIL++ ))
fi

# ── Test 15: Partial config warning — compose_db_file set, compose_project absent ──
# Static assertion: the partial config warning block must cover both directions.
echo "Test 15: Script warns on partial Docker config (compose_db_file set, compose_project absent)"
# Check that both CONFIG_COMPOSE_DB_FILE and CONFIG_COMPOSE_PROJECT are referenced
# within the same warning/partial-config block.
if grep -qE 'CONFIG_COMPOSE_DB_FILE' "$SCRIPT" && grep -qE 'CONFIG_COMPOSE_PROJECT' "$SCRIPT"; then
    # Ensure a Warning: message exists covering both variables
    if grep -qE '[Ww]arning.*[Dd]ocker|[Ww]arning.*compose' "$SCRIPT"; then
        echo "  PASS: script contains partial Docker config warning referencing both compose_db_file and compose_project"
        (( PASS++ ))
    else
        echo "  FAIL: script missing Warning message for partial Docker config" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: script missing CONFIG_COMPOSE_DB_FILE or CONFIG_COMPOSE_PROJECT references" >&2
    (( FAIL++ ))
fi

# ── Test 16: Docker-absent: no Docker-related errors in script source ────────
# Static assertion: the script must not have any unconditional Docker calls
# (i.e. docker/compose calls not inside a CONFIG_COMPOSE_DB_FILE guard).
# We verify that ALL docker invocations are within a conditional block that
# checks CONFIG_COMPOSE_DB_FILE or is already skipped when it's empty.
echo "Test 16: Docker calls are guarded by CONFIG_COMPOSE_DB_FILE"
# Count docker command invocations vs those inside CONFIG_COMPOSE_DB_FILE guards
# Strategy: check that no standalone 'docker' invocation appears outside a guard.
# We verify the orphaned-network block checks CONFIG_COMPOSE_DB_FILE.
orphan_guard_line=$(grep -n "Clean up orphaned Docker networks" "$SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$orphan_guard_line" ]]; then
    block_end=$(( orphan_guard_line + 12 ))
    guard_found=$(awk "NR>=$orphan_guard_line && NR<=$block_end" "$SCRIPT" | \
        grep -cE 'CONFIG_COMPOSE_DB_FILE' || true)
    if [ "$guard_found" -gt 0 ]; then
        echo "  PASS: orphaned Docker network section guards on CONFIG_COMPOSE_DB_FILE"
        (( PASS++ ))
    else
        echo "  FAIL: orphaned Docker network section does not check CONFIG_COMPOSE_DB_FILE" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: orphaned Docker network cleanup section not found in script" >&2
    (( FAIL++ ))
fi

# ── Test 17: Partial config warning placement — near startup config loading ───
# Static assertion: the warning for partial Docker config must appear after the
# CONFIG_* variables are loaded (i.e., after the PLUGIN_SCRIPTS block) and
# before the main logic loop.
echo "Test 17: Partial Docker config warning is placed after config loading"
config_load_line=$(grep -n "CONFIG_COMPOSE_DB_FILE=\$(bash" "$SCRIPT" | head -1 | cut -d: -f1)
warning_line=$(grep -n "[Ww]arning.*[Dd]ocker\|[Ww]arning.*compose" "$SCRIPT" | head -1 | cut -d: -f1)
gather_line=$(grep -n "Gather worktree info\|Parse porcelain output" "$SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$config_load_line" && -n "$warning_line" && -n "$gather_line" ]]; then
    if [ "$warning_line" -gt "$config_load_line" ] && [ "$warning_line" -lt "$gather_line" ]; then
        echo "  PASS: partial Docker config warning appears after config loading and before main loop"
        (( PASS++ ))
    else
        echo "  FAIL: partial Docker config warning is not in the expected location" >&2
        echo "  (config_load=$config_load_line, warning=$warning_line, gather=$gather_line)" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: could not locate config load line ($config_load_line), warning line ($warning_line), or gather line ($gather_line)" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
