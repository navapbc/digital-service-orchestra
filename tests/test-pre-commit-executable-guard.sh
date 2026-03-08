#!/usr/bin/env bash
# lockpick-workflow/tests/test-pre-commit-executable-guard.sh
# Tests for the migrated pre-commit-executable-guard.sh script.
#
# Verifies:
#   a. Canonical script detects mode regression for .sh files outside scripts/
#   b. The tee pattern (cf0a fix) produces non-empty output in worktree contexts
#   c. The wrapper delegates correctly to the canonical script
#   d. Shebang filter still applies (non-shebang .sh files are skipped)
#
# Manual run:
#   bash lockpick-workflow/tests/test-pre-commit-executable-guard.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_SCRIPT="$SCRIPT_DIR/../scripts/pre-commit-executable-guard.sh"
WRAPPER_SCRIPT="$SCRIPT_DIR/../../scripts/pre-commit-executable-guard.sh"

FAILURES=0
TESTS=0

pass() { TESTS=$((TESTS + 1)); echo "  PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }

echo "=== Tests for pre-commit-executable-guard.sh ==="

# ---------------------------------------------------------------------------
# Pre-flight: canonical script must exist
# ---------------------------------------------------------------------------
if [ ! -f "$CANONICAL_SCRIPT" ]; then
    echo "ERROR: Canonical script not found: $CANONICAL_SCRIPT"
    echo "FAILED: Cannot run tests without the canonical script."
    exit 1
fi

# ---------------------------------------------------------------------------
# Setup: create a temp git repo to simulate staged files with mode changes.
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
trap "rm -rf '$TMPDIR_BASE'" EXIT

REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO/scripts" "$REPO/hooks" "$REPO/lockpick-workflow/scripts"
cd "$REPO"

# Initialize git repo
git init -q
git config user.email "test@test.com"
git config user.name "Test"
# Create main branch reference so REF="main" resolves
git checkout -q -b main 2>/dev/null || true

# Helper: reset repo to clean state
reset_repo() {
    # Remove any staged or unstaged changes
    git reset -q HEAD -- . 2>/dev/null || true
    git checkout -- . 2>/dev/null || true
}

# Helper: run the canonical script within the temp repo
# Sets RUN_OUTPUT and RUN_EXIT
run_guard() {
    RUN_OUTPUT=""
    RUN_EXIT=0
    RUN_OUTPUT=$(
        cd "$REPO" && bash "$CANONICAL_SCRIPT" 2>&1
    ) || RUN_EXIT=$?
}

# ---------------------------------------------------------------------------
# Test a: Detects mode regression for .sh files OUTSIDE scripts/
#   - Create a .sh file with shebang in hooks/ (not scripts/)
#   - Commit it as 100755 on main
#   - Stage a modification with 100644 mode
#   - Expect exit 1 (mode regression detected)
# ---------------------------------------------------------------------------
echo ""
echo "Test a: Mode regression detected for .sh files outside scripts/"

# Create a shell script with shebang in hooks/ directory
cat > "$REPO/hooks/my-hook.sh" << 'EOF'
#!/bin/bash
echo "hook"
EOF

# Stage and commit as 100755 (create initial commit on main with correct mode)
git add hooks/my-hook.sh
git update-index --chmod=+x hooks/my-hook.sh
git commit -q -m "initial: add hook"

# Now simulate a mode-losing modification: modify the file and stage with 644
echo "# modified" >> "$REPO/hooks/my-hook.sh"
git add hooks/my-hook.sh
git update-index --chmod=-x hooks/my-hook.sh

run_guard

if [ "$RUN_EXIT" -ne 0 ]; then
    pass "outside-scripts mode regression: exit non-zero (error detected)"
else
    fail "outside-scripts mode regression: expected exit non-zero, got 0 (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "hooks/my-hook.sh"; then
    pass "outside-scripts mode regression: output mentions hooks/my-hook.sh"
else
    fail "outside-scripts mode regression: output does not mention hooks/my-hook.sh (output: $RUN_OUTPUT)"
fi

# Reset for next test
git reset -q HEAD~1 -- . 2>/dev/null || true
git reset -q --hard HEAD 2>/dev/null || true
git clean -qfd 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test b: tee pattern (cf0a fix) — tmpfile is non-empty when files are staged
#   We verify the script uses | tee pattern rather than > redirect.
#   This is a static check of the script content (structural proof of fix).
# ---------------------------------------------------------------------------
echo ""
echo "Test b: cf0a fix — tee pattern is present in canonical script"

if grep -q "tee" "$CANONICAL_SCRIPT"; then
    pass "cf0a fix: canonical script contains tee pattern"
else
    fail "cf0a fix: canonical script does NOT contain tee pattern"
fi

if grep -q '> "\$tmpfile"' "$CANONICAL_SCRIPT" 2>/dev/null || grep -q "> \"\$tmpfile\"" "$CANONICAL_SCRIPT" 2>/dev/null; then
    fail "cf0a fix: raw redirect '> \$tmpfile' still present (should use tee)"
else
    pass "cf0a fix: raw redirect '> \$tmpfile' not found (replaced by tee)"
fi

# ---------------------------------------------------------------------------
# Test c: Wrapper delegates correctly to canonical script
#   - Wrapper must exist
#   - Wrapper must contain exec delegation line pointing to lockpick-workflow/scripts/pre-commit-executable-guard.sh
#   - Wrapper must be under 15 lines
# ---------------------------------------------------------------------------
echo ""
echo "Test c: Wrapper delegation"

if [ ! -f "$WRAPPER_SCRIPT" ]; then
    fail "wrapper exists at scripts/pre-commit-executable-guard.sh"
else
    pass "wrapper exists at scripts/pre-commit-executable-guard.sh"

    LINE_COUNT=$(wc -l < "$WRAPPER_SCRIPT")
    if [ "$LINE_COUNT" -le 15 ]; then
        pass "wrapper is thin (<= 15 lines, actual: $LINE_COUNT)"
    else
        fail "wrapper is too long (expected <= 15 lines, got $LINE_COUNT)"
    fi

    if grep -q "exec.*lockpick-workflow/scripts/pre-commit-executable-guard.sh" "$WRAPPER_SCRIPT"; then
        pass "wrapper contains exec delegation to canonical script"
    else
        fail "wrapper does NOT contain exec delegation to canonical script"
    fi
fi

# ---------------------------------------------------------------------------
# Test d: Shebang filter — .sh file without shebang is skipped
#   - Create a .sh file WITHOUT shebang, staged with 100644 (after being 100755)
#   - Guard should exit 0 (no error, file skipped)
# ---------------------------------------------------------------------------
echo ""
echo "Test d: Shebang filter — non-shebang .sh file is skipped"

# Re-init the repo state for this test
git init -q "$TMPDIR_BASE/repo2"
REPO2="$TMPDIR_BASE/repo2"
cd "$REPO2"
git config user.email "test@test.com"
git config user.name "Test"
git checkout -q -b main 2>/dev/null || true

mkdir -p "$REPO2/scripts"
# Create a .sh file WITHOUT a shebang line
cat > "$REPO2/scripts/no-shebang.sh" << 'EOF'
# This script has no shebang
echo "hello"
EOF

git -C "$REPO2" add scripts/no-shebang.sh
git -C "$REPO2" update-index --chmod=+x scripts/no-shebang.sh
git -C "$REPO2" commit -q -m "initial: add no-shebang script"

# Modify and stage with 644 (mode regression, but no shebang — should be skipped)
echo "# modified" >> "$REPO2/scripts/no-shebang.sh"
git -C "$REPO2" add scripts/no-shebang.sh
git -C "$REPO2" update-index --chmod=-x scripts/no-shebang.sh

NO_SHEBANG_OUTPUT=""
NO_SHEBANG_EXIT=0
NO_SHEBANG_OUTPUT=$(
    cd "$REPO2" && bash "$CANONICAL_SCRIPT" 2>&1
) || NO_SHEBANG_EXIT=$?

if [ "$NO_SHEBANG_EXIT" -eq 0 ]; then
    pass "shebang filter: non-shebang .sh mode regression is skipped (exit 0)"
else
    fail "shebang filter: expected exit 0 for non-shebang .sh, got $NO_SHEBANG_EXIT (output: $NO_SHEBANG_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Test e: Files under scripts/ still detected (regression: old behavior preserved)
# ---------------------------------------------------------------------------
echo ""
echo "Test e: Mode regression detected for .sh files UNDER scripts/ (regression test)"

REPO3="$TMPDIR_BASE/repo3"
git init -q "$REPO3"
cd "$REPO3"
git config user.email "test@test.com"
git config user.name "Test"
git checkout -q -b main 2>/dev/null || true

mkdir -p "$REPO3/scripts"
cat > "$REPO3/scripts/my-script.sh" << 'EOF'
#!/bin/bash
echo "script"
EOF

git -C "$REPO3" add scripts/my-script.sh
git -C "$REPO3" update-index --chmod=+x scripts/my-script.sh
git -C "$REPO3" commit -q -m "initial: add my-script"

echo "# modified" >> "$REPO3/scripts/my-script.sh"
git -C "$REPO3" add scripts/my-script.sh
git -C "$REPO3" update-index --chmod=-x scripts/my-script.sh

SCRIPTS_OUTPUT=""
SCRIPTS_EXIT=0
SCRIPTS_OUTPUT=$(
    cd "$REPO3" && bash "$CANONICAL_SCRIPT" 2>&1
) || SCRIPTS_EXIT=$?

if [ "$SCRIPTS_EXIT" -ne 0 ]; then
    pass "scripts/ regression: mode loss in scripts/ still detected (exit non-zero)"
else
    fail "scripts/ regression: expected exit non-zero, got 0 (output: $SCRIPTS_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Test f: .pre-commit-config.yaml filter is absent or broad (not ^scripts/)
#   - Static check: the executable-guard entry must NOT have files: ^scripts/
#   - Ensures the hook fires for .sh files outside scripts/ directory
# ---------------------------------------------------------------------------
echo ""
echo "Test f: .pre-commit-config.yaml executable-guard filter is broad (not ^scripts/)"

# Walk up from the test script to find the repo root (where .pre-commit-config.yaml lives)
PRECOMMIT_CONFIG=""
SEARCH_DIR="$SCRIPT_DIR"
for _ in 1 2 3 4 5; do
    SEARCH_DIR="$(dirname "$SEARCH_DIR")"
    if [ -f "$SEARCH_DIR/.pre-commit-config.yaml" ]; then
        PRECOMMIT_CONFIG="$SEARCH_DIR/.pre-commit-config.yaml"
        break
    fi
done

if [ -z "$PRECOMMIT_CONFIG" ]; then
    fail "pre-commit filter: .pre-commit-config.yaml not found in any parent directory"
else
    if grep -A5 "id: executable-guard" "$PRECOMMIT_CONFIG" | grep -q "files: \^scripts/"; then
        fail "pre-commit filter: executable-guard has 'files: ^scripts/' — hook won't fire outside scripts/ (fix: change to 'files: \\.sh\$' or remove)"
    else
        pass "pre-commit filter: executable-guard does NOT restrict to '^scripts/' — hook fires for all .sh files"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $((TESTS - FAILURES))/$TESTS passed ==="
if (( FAILURES > 0 )); then
    echo "FAILED: $FAILURES test(s) failed"
    exit 1
else
    echo "All tests passed."
    exit 0
fi
