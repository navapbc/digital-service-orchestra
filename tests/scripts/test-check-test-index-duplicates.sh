#!/usr/bin/env bash
# tests/scripts/test-check-test-index-duplicates.sh
# Behavioral tests for plugins/dso/scripts/check-test-index-duplicates.sh
# (bug 6dd3-8d54 — guard auto-unions duplicate .test-index keys).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/plugins/dso/scripts/check-test-index-duplicates.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

_make_fixture_repo() {
    local d
    d=$(mktemp -d)
    (
        cd "$d" || exit 1
        git init -q
        git config user.email test@example.com
        git config user.name test
        git commit --allow-empty -m init -q
    )
    echo "$d"
}

test_no_op_on_clean_file() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
# header
src/a.py:tests/a.sh
src/b.py:tests/b.sh,tests/b2.sh
EOF
    local before_sum; before_sum=$(cksum < "$repo/.test-index")
    ( cd "$repo" && bash "$GUARD" )
    assert_eq "clean file: exit 0" "0" "$?"
    local after_sum; after_sum=$(cksum < "$repo/.test-index")
    assert_eq "clean file: unchanged" "$before_sum" "$after_sum"
    rm -rf "$repo"
}

test_auto_unions_duplicate_keys() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a1.sh,tests/a2.sh
src/b.py:tests/b.sh
src/a.py:tests/a3.sh,tests/a1.sh
EOF
    ( cd "$repo" && bash "$GUARD" )
    assert_eq "duplicates: exit 0 after auto-fix" "0" "$?"

    # Exactly one line for src/a.py now.
    local a_count
    a_count=$(grep -c '^src/a.py:' "$repo/.test-index")
    assert_eq "src/a.py collapsed to one line" "1" "$a_count"

    # Union preserves first-occurrence order: a1, a2, a3
    local a_line
    a_line=$(grep '^src/a.py:' "$repo/.test-index")
    assert_eq "src/a.py RHS unioned in first-occurrence order" \
        "src/a.py:tests/a1.sh,tests/a2.sh,tests/a3.sh" "$a_line"
    rm -rf "$repo"
}

test_restages_if_file_was_staged() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a1.sh
src/a.py:tests/a2.sh
EOF
    ( cd "$repo" && git add .test-index && bash "$GUARD" )
    assert_eq "staged duplicates: exit 0" "0" "$?"
    # After re-stage, staged content == working-tree content
    local diff_out
    diff_out=$(cd "$repo" && git diff --cached -- .test-index | grep -cE '^[+-]src/a.py' || echo 0)
    # Staged version should reflect the unioned single line; working tree matches.
    local working_line
    working_line=$(grep '^src/a.py:' "$repo/.test-index")
    local staged_line
    staged_line=$(cd "$repo" && git show :.test-index | grep '^src/a.py:')
    assert_eq "staged line matches working-tree after auto-union" "$working_line" "$staged_line"
    rm -rf "$repo"
}

test_auto_stages_even_if_file_was_not_previously_staged() {
    # bug e0be-5826: hook must always auto-stage after union so the commit
    # proceeds in one step, even when .test-index was not already in the index.
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a1.sh
src/a.py:tests/a2.sh
EOF
    ( cd "$repo" && bash "$GUARD" )
    assert_eq "unstaged duplicates: exit 0" "0" "$?"
    # File should now be staged despite not being staged before.
    local staged
    staged=$(cd "$repo" && git diff --cached --name-only)
    assert_eq "auto-staged after union even when not previously staged" ".test-index" "$staged"
    rm -rf "$repo"
}

test_comments_not_counted_as_keys() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
# comment with src/a.py: in it
# another comment mentioning src/a.py: here
src/a.py:tests/a.sh
EOF
    local before_sum; before_sum=$(cksum < "$repo/.test-index")
    ( cd "$repo" && bash "$GUARD" )
    local after_sum; after_sum=$(cksum < "$repo/.test-index")
    assert_eq "comments ignored: file unchanged" "$before_sum" "$after_sum"
    rm -rf "$repo"
}

test_absent_file_passes() {
    local repo; repo=$(_make_fixture_repo)
    # no .test-index created
    ( cd "$repo" && bash "$GUARD" )
    assert_eq "absent file is a no-op" "0" "$?"
    rm -rf "$repo"
}

test_idempotent() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a1.sh
src/a.py:tests/a2.sh
src/b.py:tests/b.sh
EOF
    ( cd "$repo" && bash "$GUARD" )
    local first_sum; first_sum=$(cksum < "$repo/.test-index")
    ( cd "$repo" && bash "$GUARD" )
    local second_sum; second_sum=$(cksum < "$repo/.test-index")
    assert_eq "second run produces identical output (idempotent)" "$first_sum" "$second_sum"
    rm -rf "$repo"
}

echo "=== test-check-test-index-duplicates ==="
test_no_op_on_clean_file
test_auto_unions_duplicate_keys
test_restages_if_file_was_staged
test_auto_stages_even_if_file_was_not_previously_staged
test_comments_not_counted_as_keys
test_absent_file_passes
test_idempotent

print_summary
