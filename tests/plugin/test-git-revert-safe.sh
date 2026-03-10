#!/usr/bin/env bash
# lockpick-workflow/tests/plugin/test-git-revert-safe.sh
# TDD tests for git-revert-safe.sh (canonical copy in lockpick-workflow/scripts/)
#
# Output format: "PASS: <test_name>" or "FAIL: <test_name>"
# Exit 0 iff FAIL==0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
CANONICAL_SCRIPT="$PLUGIN_ROOT/scripts/git-revert-safe.sh"
WRAPPER_SCRIPT="$REPO_ROOT/scripts/git-revert-safe.sh"

PASS=0
FAIL=0

echo "=== test-git-revert-safe.sh (plugin) ==="
echo ""

# ── Helper: setup_test_repo ────────────────────────────────────────────────────
# Creates a temporary git repo with two commits:
#   Commit 1: add app/dummy.txt
#   Commit 2: modify app/dummy.txt AND add .tickets/ticket-001.md
# Returns the temp dir path via stdout.
setup_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)

    cd "$tmpdir" || return 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Commit 1: app file only
    mkdir -p app
    echo "original content" > app/dummy.txt
    git add app/dummy.txt
    git commit -q -m "Initial commit: add app/dummy.txt"

    # Commit 2: modify app file + add ticket file
    echo "modified content" > app/dummy.txt
    mkdir -p .tickets
    echo "---
id: ticket-001
status: open
---
# Test ticket" > .tickets/ticket-001.md
    git add app/dummy.txt .tickets/ticket-001.md
    git commit -q -m "Add feature: modify app file and add ticket"

    echo "$tmpdir"
}

# ── Test: canonical_script_exists ────────────────────────────────────────────
echo "Test: canonical_script_exists"
if [ -f "$CANONICAL_SCRIPT" ]; then
    echo "  PASS: test_canonical_script_exists"
    ((PASS++))
else
    echo "  FAIL: test_canonical_script_exists (git-revert-safe.sh not found at $CANONICAL_SCRIPT)"
    ((FAIL++))
fi

# ── Test: canonical_script_executable ────────────────────────────────────────
echo "Test: canonical_script_executable"
if [ -x "$CANONICAL_SCRIPT" ]; then
    echo "  PASS: test_canonical_script_executable"
    ((PASS++))
else
    echo "  FAIL: test_canonical_script_executable (canonical script not executable)"
    ((FAIL++))
fi

# ── Test: wrapper_exists_and_delegates ───────────────────────────────────────
echo "Test: wrapper_exists_and_delegates"
if [ -f "$WRAPPER_SCRIPT" ]; then
    if grep -q 'exec.*lockpick-workflow/scripts/git-revert-safe.sh' "$WRAPPER_SCRIPT"; then
        echo "  PASS: test_wrapper_exists_and_delegates"
        ((PASS++))
    else
        echo "  FAIL: test_wrapper_exists_and_delegates (wrapper does not exec to plugin copy)"
        ((FAIL++))
    fi
else
    echo "  FAIL: test_wrapper_exists_and_delegates (wrapper not found at $WRAPPER_SCRIPT)"
    ((FAIL++))
fi

# ── Test: syntax_ok ────────────────────────────────────────────────────────────
echo "Test: syntax_ok"
if bash -n "$CANONICAL_SCRIPT" 2>/dev/null; then
    echo "  PASS: test_syntax_ok"
    ((PASS++))
else
    echo "  FAIL: test_syntax_ok (bash -n reports syntax errors)"
    ((FAIL++))
fi

# ── Test: test_revert_safe_strips_ticket_files ────────────────────────────────
echo "Test: test_revert_safe_strips_ticket_files"

TMPDIR_1=$(setup_test_repo)
COMMIT2_SHA=$(git -C "$TMPDIR_1" rev-parse HEAD)

cd "$TMPDIR_1" || { echo "  FAIL: test_revert_safe_strips_ticket_files (cd failed)"; ((FAIL++)); exit 1; }
revert_output=""
revert_exit=0
revert_output=$(bash "$CANONICAL_SCRIPT" "$COMMIT2_SHA" 2>&1) || revert_exit=$?

if [ "$revert_exit" -ne 0 ]; then
    echo "  FAIL: test_revert_safe_strips_ticket_files (script exited $revert_exit: $revert_output)"
    ((FAIL++))
else
    revert_files=$(git -C "$TMPDIR_1" diff-tree --no-commit-id -r --name-only HEAD)

    if ! echo "$revert_files" | grep -q "app/dummy.txt"; then
        echo "  FAIL: test_revert_safe_strips_ticket_files (app/dummy.txt not found in revert commit)"
        echo "  Revert commit files: $revert_files"
        ((FAIL++))
    elif echo "$revert_files" | grep -q "^\.tickets/"; then
        echo "  FAIL: test_revert_safe_strips_ticket_files (.tickets/ file found in revert commit — should be stripped)"
        echo "  Revert commit files: $revert_files"
        ((FAIL++))
    else
        echo "  PASS: test_revert_safe_strips_ticket_files"
        ((PASS++))
    fi
fi

rm -rf "$TMPDIR_1"

# ── Test: test_revert_safe_include_tickets_flag ───────────────────────────────
echo "Test: test_revert_safe_include_tickets_flag"

TMPDIR_2=$(setup_test_repo)
COMMIT2_SHA=$(git -C "$TMPDIR_2" rev-parse HEAD)

cd "$TMPDIR_2" || { echo "  FAIL: test_revert_safe_include_tickets_flag (cd failed)"; ((FAIL++)); exit 1; }
revert_output=""
revert_exit=0
revert_output=$(bash "$CANONICAL_SCRIPT" --include-tickets "$COMMIT2_SHA" 2>&1) || revert_exit=$?

if [ "$revert_exit" -ne 0 ]; then
    echo "  FAIL: test_revert_safe_include_tickets_flag (script exited $revert_exit: $revert_output)"
    ((FAIL++))
else
    revert_files=$(git -C "$TMPDIR_2" diff-tree --no-commit-id -r --name-only HEAD)

    if ! echo "$revert_files" | grep -q "app/dummy.txt"; then
        echo "  FAIL: test_revert_safe_include_tickets_flag (app/dummy.txt not in revert commit)"
        echo "  Revert commit files: $revert_files"
        ((FAIL++))
    elif ! echo "$revert_files" | grep -q "^\.tickets/"; then
        echo "  FAIL: test_revert_safe_include_tickets_flag (.tickets/ file NOT in revert commit — should be included with --include-tickets)"
        echo "  Revert commit files: $revert_files"
        ((FAIL++))
    else
        echo "  PASS: test_revert_safe_include_tickets_flag"
        ((PASS++))
    fi
fi

rm -rf "$TMPDIR_2"

# ── Test: test_revert_safe_no_tickets_in_revert ───────────────────────────────
echo "Test: test_revert_safe_no_tickets_in_revert"

TMPDIR_3=$(mktemp -d)
cd "$TMPDIR_3" || { echo "  FAIL: test_revert_safe_no_tickets_in_revert (cd failed)"; ((FAIL++)); exit 1; }
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

mkdir -p app
echo "original content" > app/file.txt
git add app/file.txt
git commit -q -m "Initial commit"

echo "modified content" > app/file.txt
git add app/file.txt
git commit -q -m "Modify app file only"

COMMIT2_SHA=$(git rev-parse HEAD)

no_ticket_stderr_file=$(mktemp)
no_ticket_exit=0
bash "$CANONICAL_SCRIPT" "$COMMIT2_SHA" >"$no_ticket_stderr_file.stdout" 2>"$no_ticket_stderr_file" || no_ticket_exit=$?
no_ticket_stderr=$(cat "$no_ticket_stderr_file")
rm -f "$no_ticket_stderr_file" "$no_ticket_stderr_file.stdout"

if [ "$no_ticket_exit" -ne 0 ]; then
    echo "  FAIL: test_revert_safe_no_tickets_in_revert (script exited $no_ticket_exit)"
    ((FAIL++))
elif echo "$no_ticket_stderr" | grep -qi "warning.*ticket\|stripped"; then
    echo "  FAIL: test_revert_safe_no_tickets_in_revert (unexpected ticket warning printed)"
    echo "  stderr: $no_ticket_stderr"
    ((FAIL++))
else
    echo "  PASS: test_revert_safe_no_tickets_in_revert"
    ((PASS++))
fi

rm -rf "$TMPDIR_3"

# ── Test: test_revert_safe_prints_warning_with_filenames ─────────────────────
echo "Test: test_revert_safe_prints_warning_with_filenames"

TMPDIR_4=$(mktemp -d)
cd "$TMPDIR_4" || { echo "  FAIL: test_revert_safe_prints_warning_with_filenames (cd failed)"; ((FAIL++)); exit 1; }
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

mkdir -p app
echo "base" > app/base.txt
git add app/base.txt
git commit -q -m "Base commit"

echo "changed" > app/base.txt
mkdir -p .tickets
echo "# ticket alpha" > .tickets/ticket-alpha.md
echo "# ticket beta" > .tickets/ticket-beta.md
git add app/base.txt .tickets/ticket-alpha.md .tickets/ticket-beta.md
git commit -q -m "Change with two tickets"

COMMIT2_SHA=$(git rev-parse HEAD)

warn_stderr_file=$(mktemp)
warn_exit=0
bash "$CANONICAL_SCRIPT" "$COMMIT2_SHA" >"$warn_stderr_file.stdout" 2>"$warn_stderr_file" || warn_exit=$?
warn_stderr=$(cat "$warn_stderr_file")
rm -f "$warn_stderr_file" "$warn_stderr_file.stdout"

if [ "$warn_exit" -ne 0 ]; then
    echo "  FAIL: test_revert_safe_prints_warning_with_filenames (script exited $warn_exit: $warn_stderr)"
    ((FAIL++))
elif echo "$warn_stderr" | grep -q "ticket-alpha.md" && echo "$warn_stderr" | grep -q "ticket-beta.md"; then
    echo "  PASS: test_revert_safe_prints_warning_with_filenames"
    ((PASS++))
else
    echo "  FAIL: test_revert_safe_prints_warning_with_filenames (warning did not list ticket filenames)"
    echo "  stderr: $warn_stderr"
    ((FAIL++))
fi

rm -rf "$TMPDIR_4"

# ── Test: test_revert_safe_tickets_only_commit_aborts_cleanly ─────────────────
echo "Test: test_revert_safe_tickets_only_commit_aborts_cleanly"

TMPDIR_5=$(mktemp -d)
cd "$TMPDIR_5" || { echo "  FAIL: test_revert_safe_tickets_only_commit_aborts_cleanly (cd failed)"; ((FAIL++)); exit 1; }
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

mkdir -p app
echo "base" > app/base.txt
git add app/base.txt
git commit -q -m "Base commit"

mkdir -p .tickets
echo "# ticket only" > .tickets/ticket-only.md
git add .tickets/ticket-only.md
git commit -q -m "Add ticket file only"

COMMIT2_SHA=$(git rev-parse HEAD)
HEAD_BEFORE=$(git rev-parse HEAD)

tickets_only_stderr_file=$(mktemp)
tickets_only_exit=0
bash "$CANONICAL_SCRIPT" "$COMMIT2_SHA" >"$tickets_only_stderr_file.stdout" 2>"$tickets_only_stderr_file" || tickets_only_exit=$?
tickets_only_stderr=$(cat "$tickets_only_stderr_file")
rm -f "$tickets_only_stderr_file" "$tickets_only_stderr_file.stdout"

HEAD_AFTER=$(git rev-parse HEAD)

if [ "$tickets_only_exit" -ne 0 ]; then
    echo "  FAIL: test_revert_safe_tickets_only_commit_aborts_cleanly (script exited $tickets_only_exit, expected 0)"
    echo "  stderr: $tickets_only_stderr"
    ((FAIL++))
elif [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]; then
    echo "  FAIL: test_revert_safe_tickets_only_commit_aborts_cleanly (HEAD changed — unexpected commit created)"
    ((FAIL++))
elif [ -n "$(git status --porcelain)" ]; then
    echo "  FAIL: test_revert_safe_tickets_only_commit_aborts_cleanly (working tree not clean)"
    echo "  status: $(git status --porcelain)"
    ((FAIL++))
elif ! echo "$tickets_only_stderr" | grep -qi "empty.*abort\|abort.*empty\|empty after stripping"; then
    echo "  FAIL: test_revert_safe_tickets_only_commit_aborts_cleanly (no abort warning in stderr)"
    echo "  stderr: $tickets_only_stderr"
    ((FAIL++))
else
    echo "  PASS: test_revert_safe_tickets_only_commit_aborts_cleanly"
    ((PASS++))
fi

rm -rf "$TMPDIR_5"

# ── Test: test_wrapper_delegates_to_canonical ─────────────────────────────────
# Verify the wrapper at scripts/git-revert-safe.sh correctly delegates to the
# canonical copy by running a real revert through the wrapper path.
echo "Test: test_wrapper_delegates_to_canonical"

TMPDIR_6=$(setup_test_repo)
COMMIT2_SHA=$(git -C "$TMPDIR_6" rev-parse HEAD)

cd "$TMPDIR_6" || { echo "  FAIL: test_wrapper_delegates_to_canonical (cd failed)"; ((FAIL++)); exit 1; }
wrapper_exit=0
wrapper_output=$(bash "$WRAPPER_SCRIPT" "$COMMIT2_SHA" 2>&1) || wrapper_exit=$?

if [ "$wrapper_exit" -ne 0 ]; then
    echo "  FAIL: test_wrapper_delegates_to_canonical (wrapper exited $wrapper_exit: $wrapper_output)"
    ((FAIL++))
else
    revert_files=$(git -C "$TMPDIR_6" diff-tree --no-commit-id -r --name-only HEAD)
    if ! echo "$revert_files" | grep -q "app/dummy.txt"; then
        echo "  FAIL: test_wrapper_delegates_to_canonical (app/dummy.txt not in revert commit via wrapper)"
        ((FAIL++))
    elif echo "$revert_files" | grep -q "^\.tickets/"; then
        echo "  FAIL: test_wrapper_delegates_to_canonical (.tickets/ in revert commit via wrapper)"
        ((FAIL++))
    else
        echo "  PASS: test_wrapper_delegates_to_canonical"
        ((PASS++))
    fi
fi

rm -rf "$TMPDIR_6"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
