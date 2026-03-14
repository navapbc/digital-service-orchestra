#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-review-gate-non-reviewable.sh
# Tests that the review gate skips review for non-reviewable file commits.
#
# Regression test for lockpick-doc-to-logic-vupb:
#   Ticket-only commits (.tickets/* files) were blocked by "Review is stale"
#   even though .tickets/ is listed as non-reviewable.
#
# Tests:
#   test_review_gate_allows_ticket_only_commit_via_staged_files
#   test_review_gate_allows_docs_only_commit_via_staged_files
#   test_review_gate_allows_claude_docs_only_commit_via_staged_files
#   test_review_gate_allows_mixed_non_reviewable_commit
#   test_review_gate_blocks_commit_with_code_files
#   test_review_gate_allows_ticket_only_via_git_add_targets
#   test_review_gate_allows_non_reviewable_via_git_add_targets
#   test_review_gate_skip_review_check_integration

REPO_ROOT="$(git rev-parse --show-toplevel)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"

# Run hook_review_gate in a fresh temporary git repo with specified staged files.
# Args: JSON input, then file paths to create and stage (relative to repo root).
# Files in .tickets/, docs/, .claude/docs/ are created with placeholder content.
# Returns the exit code of hook_review_gate.
_run_in_temp_repo() {
    local input="$1"
    shift
    local files=("$@")

    local tmpdir
    tmpdir=$(mktemp -d)

    (
        cd "$tmpdir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -q -m "init"

        # Create and stage the specified files
        for f in "${files[@]}"; do
            mkdir -p "$(dirname "$f")"
            echo "test content" > "$f"
            git add "$f"
        done

        # Source the functions again in this subshell context
        source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
        source "$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"

        local exit_code=0
        hook_review_gate "$input" 2>/dev/null || exit_code=$?
        exit "$exit_code"
    )
    local result=$?
    rm -rf "$tmpdir"
    return $result
}

# ============================================================
# test_review_gate_allows_ticket_only_commit_via_staged_files
# When only .tickets/ files are staged, the review gate should allow.
# ============================================================
echo "--- test_review_gate_allows_ticket_only_commit_via_staged_files ---"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"chore: update ticket\""}}'
EXIT_CODE=0
_run_in_temp_repo "$INPUT" ".tickets/test-ticket.md" || EXIT_CODE=$?

assert_eq "test_review_gate_allows_ticket_only_commit_via_staged_files" "0" "$EXIT_CODE"

# ============================================================
# test_review_gate_allows_docs_only_commit_via_staged_files
# When only docs/ files are staged, the review gate should allow.
# ============================================================
echo "--- test_review_gate_allows_docs_only_commit_via_staged_files ---"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: update guide\""}}'
EXIT_CODE=0
_run_in_temp_repo "$INPUT" "docs/guide.md" || EXIT_CODE=$?

assert_eq "test_review_gate_allows_docs_only_commit_via_staged_files" "0" "$EXIT_CODE"

# ============================================================
# test_review_gate_allows_claude_docs_only_commit_via_staged_files
# When only .claude/docs/ files are staged, the review gate should allow.
# ============================================================
echo "--- test_review_gate_allows_claude_docs_only_commit_via_staged_files ---"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: update known issues\""}}'
EXIT_CODE=0
_run_in_temp_repo "$INPUT" ".claude/docs/KNOWN-ISSUES.md" || EXIT_CODE=$?

assert_eq "test_review_gate_allows_claude_docs_only_commit_via_staged_files" "0" "$EXIT_CODE"

# ============================================================
# test_review_gate_allows_mixed_non_reviewable_commit
# When staged files are a mix of non-reviewable types (.tickets/ + docs/),
# the review gate should allow.
# ============================================================
echo "--- test_review_gate_allows_mixed_non_reviewable_commit ---"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"chore: update tickets and docs\""}}'
EXIT_CODE=0
_run_in_temp_repo "$INPUT" ".tickets/test-ticket.md" "docs/guide.md" ".claude/docs/NOTES.md" || EXIT_CODE=$?

assert_eq "test_review_gate_allows_mixed_non_reviewable_commit" "0" "$EXIT_CODE"

# ============================================================
# test_review_gate_blocks_commit_with_code_files
# When staged files include a code file, the review gate should block
# (since there's no review state in the temp repo).
# ============================================================
echo "--- test_review_gate_blocks_commit_with_code_files ---"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"feat: add feature\""}}'
EXIT_CODE=0
_run_in_temp_repo "$INPUT" ".tickets/test-ticket.md" "src/main.py" || EXIT_CODE=$?

assert_eq "test_review_gate_blocks_commit_with_code_files" "2" "$EXIT_CODE"

# ============================================================
# test_review_gate_allows_ticket_only_via_git_add_targets
# When the command is 'git add .tickets/... && git commit', the hook
# should parse targets and allow without needing prior staging.
# ============================================================
echo "--- test_review_gate_allows_ticket_only_via_git_add_targets ---"

# This test uses the git add target parsing (no pre-staging needed)
TMPDIR_TEST=$(mktemp -d)
(
    cd "$TMPDIR_TEST"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -q -m "init"
    mkdir -p .tickets
    echo "status: open" > .tickets/test-ticket.md

    source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
    source "$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"

    INPUT='{"tool_name":"Bash","tool_input":{"command":"git add .tickets/test-ticket.md && git commit -m \"chore: update ticket\""}}'
    exit_code=0
    hook_review_gate "$INPUT" 2>/dev/null || exit_code=$?
    exit "$exit_code"
)
EXIT_CODE=$?
rm -rf "$TMPDIR_TEST"
assert_eq "test_review_gate_allows_ticket_only_via_git_add_targets" "0" "$EXIT_CODE"

# ============================================================
# test_review_gate_allows_non_reviewable_via_git_add_targets
# When git add targets are all non-reviewable paths (.tickets/ + docs/),
# the hook should allow without needing review.
# ============================================================
echo "--- test_review_gate_allows_non_reviewable_via_git_add_targets ---"

TMPDIR_TEST=$(mktemp -d)
(
    cd "$TMPDIR_TEST"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -q -m "init"
    mkdir -p .tickets docs .claude/docs
    echo "status: open" > .tickets/test-ticket.md
    echo "# Doc" > docs/guide.md
    echo "# Notes" > .claude/docs/NOTES.md

    source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
    source "$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"

    INPUT='{"tool_name":"Bash","tool_input":{"command":"git add .tickets/test-ticket.md docs/guide.md .claude/docs/NOTES.md && git commit -m \"chore: update non-reviewable files\""}}'
    exit_code=0
    hook_review_gate "$INPUT" 2>/dev/null || exit_code=$?
    exit "$exit_code"
)
EXIT_CODE=$?
rm -rf "$TMPDIR_TEST"
assert_eq "test_review_gate_allows_non_reviewable_via_git_add_targets" "0" "$EXIT_CODE"

# ============================================================
# test_review_gate_skip_review_check_integration
# The hook should use skip-review-check.sh or equivalent logic
# to determine non-reviewable status.
# ============================================================
echo "--- test_review_gate_skip_review_check_integration ---"

# Verify that the hook function references non-reviewable/skip-review logic
HOOK_FUNCTIONS_FILE="$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"
SKIP_REVIEW_REF=$(grep -c 'skip.review\|non.reviewable\|SKIP_REVIEW\|skip_review_check' "$HOOK_FUNCTIONS_FILE" 2>/dev/null || echo "0")
assert_ne "test_review_gate_skip_review_check_integration: hook references skip-review logic" "0" "$SKIP_REVIEW_REF"

print_summary
