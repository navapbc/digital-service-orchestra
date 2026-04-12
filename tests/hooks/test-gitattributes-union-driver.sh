#!/usr/bin/env bash
# Test that .gitattributes configures merge=union for .test-index,
# ensuring concurrent worktree appends merge without conflicts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

# ── Test 1: .gitattributes contains merge=union for .test-index ──
GITATTR_CONTENT=$(cat "$REPO_ROOT/.gitattributes" 2>/dev/null || echo "")
assert_contains "merge_union_entry" "merge=union" "$GITATTR_CONTENT"
assert_contains "test_index_pattern" ".test-index" "$GITATTR_CONTENT"

# ── Helper: set up temp repo with .gitattributes ──
setup_repo() {
    cd "$TEST_DIR"
    rm -rf .git .test-index .gitattributes 2>/dev/null || true
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    cp "$REPO_ROOT/.gitattributes" "$TEST_DIR/.gitattributes"
    cat > .test-index <<'EOF'
# .test-index — auto-generated
EOF
    git add .gitattributes .test-index
    git commit -q -m "initial"
}

# ── Test 2: Non-overlapping appends merge without conflict ──
setup_repo

git checkout -q -b branch-a
cat >> .test-index <<'EOF'
src/module_a.py:tests/test_module_a.py
src/module_b.py:tests/test_module_b.py
EOF
git add .test-index && git commit -q -m "branch-a entries"

git checkout -q main 2>/dev/null || git checkout -q master
git checkout -q -b branch-b
cat >> .test-index <<'EOF'
src/module_c.py:tests/test_module_c.py
src/module_d.py:tests/test_module_d.py
EOF
git add .test-index && git commit -q -m "branch-b entries"

MERGE_EXIT=0
git merge branch-a -m "merge" 2>&1 || MERGE_EXIT=$?
assert_eq "non_overlapping_merge_succeeds" "0" "$MERGE_EXIT"

MERGED_CONTENT=$(cat .test-index)
NO_CONFLICT_MARKERS=true
echo "$MERGED_CONTENT" | grep -q '<<<<<<<' && NO_CONFLICT_MARKERS=false
assert_eq "non_overlapping_no_conflict_markers" "true" "$NO_CONFLICT_MARKERS"

assert_contains "branch_a_entry_1" "src/module_a.py" "$MERGED_CONTENT"
assert_contains "branch_a_entry_2" "src/module_b.py" "$MERGED_CONTENT"
assert_contains "branch_b_entry_1" "src/module_c.py" "$MERGED_CONTENT"
assert_contains "branch_b_entry_2" "src/module_d.py" "$MERGED_CONTENT"

# ── Test 3: Overlapping appends (both add same entry) merge without conflict ──
setup_repo

git checkout -q -b branch-x
echo "src/shared.py:tests/test_shared.py" >> .test-index
git add .test-index && git commit -q -m "branch-x adds shared"

git checkout -q main 2>/dev/null || git checkout -q master
git checkout -q -b branch-y
echo "src/shared.py:tests/test_shared.py" >> .test-index
git add .test-index && git commit -q -m "branch-y adds shared"

MERGE_EXIT_OVERLAP=0
git merge branch-x -m "merge-overlap" 2>&1 || MERGE_EXIT_OVERLAP=$?
assert_eq "overlapping_merge_succeeds" "0" "$MERGE_EXIT_OVERLAP"

OVERLAP_CONTENT=$(cat .test-index)
NO_CONFLICT_OVERLAP=true
echo "$OVERLAP_CONTENT" | grep -q '<<<<<<<' && NO_CONFLICT_OVERLAP=false
assert_eq "overlapping_no_conflict_markers" "true" "$NO_CONFLICT_OVERLAP"

assert_contains "overlapping_entry_present" "src/shared.py" "$OVERLAP_CONTENT"

print_summary
