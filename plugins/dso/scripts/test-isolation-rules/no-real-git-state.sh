#!/usr/bin/env bash
set -uo pipefail
# Rule: no-real-git-state
# Detects test files that read git state (MERGE_HEAD, REBASE_HEAD, git-dir)
# from the real worktree instead of creating an isolated git repo.
#
# Tests that call `git rev-parse --git-dir` or read `.git/MERGE_HEAD` without
# creating their own temp git repo (via `git init`) will see the real worktree's
# merge/rebase state, causing spurious failures during merge operations.
#
# Detected patterns:
#   - `git rev-parse --git-dir` without a corresponding `git init` in the file
#   - Direct reads of `.git/MERGE_HEAD` or `.git/REBASE_HEAD` without isolation
#   - Running scripts that call `_is_merge_commit` (e.g., the classifier)
#     without passing CLASSIFIER_GIT_DIR
#
# Allowed patterns (not flagged):
#   - Files that create their own git repo: `git init`, `make_test_repo`,
#     `setup_test_repo`, `git -C "$tmpdir" init`
#   - Files that pass CLASSIFIER_GIT_DIR or TEST_GIT_DIR to isolate
#   - Lines with `# isolation-ok:` suppression comment
#
# Rule contract:
#   - Receives a file path as $1
#   - Outputs violations as file:line:no-real-git-state:message to stdout
#   - Exits 0 (violations reported via stdout, not exit code)

file="$1"

# Only check bash/shell test files
basename_file="$(basename "$file")"
case "$basename_file" in
    test*.sh|test*.bash) ;;
    *) exit 0 ;;
esac

# Quick check: does the file reference git-dir or MERGE_HEAD at all?
if ! grep -qE 'git rev-parse --git-dir|\.git/MERGE_HEAD|\.git/REBASE_HEAD|review-complexity-classifier' "$file" 2>/dev/null; then
    exit 0
fi

# Check if the file creates its own isolated git repo
has_isolation=false
if grep -qE 'git init|git -C .* init|make_test_repo|setup_test_repo' "$file" 2>/dev/null; then
    has_isolation=true
fi

# Check if the file passes isolation env vars to the classifier
if grep -qE 'CLASSIFIER_GIT_DIR|TEST_GIT_DIR' "$file" 2>/dev/null; then
    has_isolation=true
fi

# If file has isolation, no violations
if $has_isolation; then
    exit 0
fi

# File reads git state without isolation — report violations
line_num=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))

    # Skip suppressed lines
    if [[ "$line" == *"# isolation-ok:"* ]]; then
        continue
    fi

    # Flag git rev-parse --git-dir
    if [[ "$line" == *"git rev-parse --git-dir"* ]]; then
        echo "$file:$line_num:no-real-git-state:reads git-dir from real worktree without isolated repo — create a temp git repo via 'git init' or pass CLASSIFIER_GIT_DIR"
    fi

    # Flag .git/MERGE_HEAD reads
    if [[ "$line" == *".git/MERGE_HEAD"* ]] || [[ "$line" == *"MERGE_HEAD"* && "$line" != *"MOCK_MERGE_HEAD"* && "$line" != *"CLASSIFIER_GIT_DIR"* ]]; then
        # Only flag if it looks like a file read (test -f, cat, head, -s, etc.)
        if [[ "$line" =~ (test[[:space:]]+-[fsre]|cat[[:space:]]|head[[:space:]]|-s[[:space:]]) ]]; then
            echo "$file:$line_num:no-real-git-state:reads MERGE_HEAD from real worktree — create isolated git repo or use CLASSIFIER_GIT_DIR"
        fi
    fi

    # Flag running the classifier without CLASSIFIER_GIT_DIR
    if [[ "$line" == *"review-complexity-classifier"* ]] && [[ "$line" != *"CLASSIFIER_GIT_DIR"* ]]; then
        echo "$file:$line_num:no-real-git-state:runs classifier without CLASSIFIER_GIT_DIR — classifier will read real MERGE_HEAD during merges"
    fi
done < "$file"

exit 0
