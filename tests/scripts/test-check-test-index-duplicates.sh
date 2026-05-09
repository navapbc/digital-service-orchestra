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

# ── Test bbf6-4778 (RED): marker-only duplicates in test list collapsed to first marker ──
# Same source file, same test file, different RED markers → should be collapsed.
# RED: current dedup logic treats "tests/a.sh [markerA]" and "tests/a.sh [markerB]" as
#      distinct strings and preserves both. After fix, only the first marker survives.
test_collapses_marker_only_duplicates_in_test_list() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a.sh [markerA],tests/a.sh [markerB],tests/a.sh [markerC],tests/b.sh
EOF
    ( cd "$repo" && bash "$GUARD" )
    assert_eq "marker-only dups: exit 0 after auto-fix" "0" "$?"
    local a_line
    a_line=$(grep '^src/a.py:' "$repo/.test-index")
    assert_eq "marker-only dups collapsed to first marker" \
        "src/a.py:tests/a.sh [markerA],tests/b.sh" "$a_line"
    rm -rf "$repo"
}

# ── Test bbf6-4778b (RED): marker-only dups across separate source-key lines also collapsed ──
test_collapses_marker_only_dups_across_source_key_lines() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a.sh [markerA]
src/a.py:tests/a.sh [markerB],tests/b.sh
EOF
    ( cd "$repo" && bash "$GUARD" )
    assert_eq "cross-line marker-only dups: exit 0 after auto-fix" "0" "$?"
    # Source key collapsed to one line
    local a_count
    a_count=$(grep -c '^src/a.py:' "$repo/.test-index")
    assert_eq "cross-line dups: one src/a.py line" "1" "$a_count"
    local a_line
    a_line=$(grep '^src/a.py:' "$repo/.test-index")
    assert_eq "cross-line dups: first marker kept, second dropped" \
        "src/a.py:tests/a.sh [markerA],tests/b.sh" "$a_line"
    rm -rf "$repo"
}

# ── Test 804a-84c7 (RED): cross-source-key same-test-file marker conflict rejected ──
# When the same test file appears under two different source-key lines each with a
# different RED marker, the guard must exit 1 (not auto-fix). The bash-runner
# last-entry-wins means only the last marker survives, silently breaking the first.
test_rejects_cross_source_key_marker_conflict() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/shared.sh [markerA]
src/b.py:tests/shared.sh [markerB],tests/b.sh
EOF
    local exit_code=0
    local stderr_out
    stderr_out=$( cd "$repo" && bash "$GUARD" 2>&1 ) || exit_code=$?
    assert_eq "cross-key marker conflict: exit 1" "1" "$exit_code"
    # Error must mention the conflicting test file
    if [[ "$stderr_out" == *"tests/shared.sh"* ]]; then
        assert_eq "cross-key marker conflict: error names conflicting file" "has-file" "has-file"
    else
        assert_eq "cross-key marker conflict: error names conflicting file" "has-file" "missing: $stderr_out"
    fi
    # Error must mention both markers
    if [[ "$stderr_out" == *"markerA"* ]] && [[ "$stderr_out" == *"markerB"* ]]; then
        assert_eq "cross-key marker conflict: error names both markers" "has-both" "has-both"
    else
        assert_eq "cross-key marker conflict: error names both markers" "has-both" "missing: $stderr_out"
    fi
    rm -rf "$repo"
}

# ── Test 804a-84c7b (RED): same test file, no markers on either line — not an error ──
# Only marker conflicts are rejected. A test file appearing under two source keys
# without any RED marker is a valid (common) pattern and must not be rejected.
test_allows_cross_source_key_no_marker_duplicate() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/shared.sh
src/b.py:tests/shared.sh,tests/b.sh
EOF
    local before_sum; before_sum=$(cksum < "$repo/.test-index")
    local exit_code=0
    ( cd "$repo" && bash "$GUARD" ) || exit_code=$?
    assert_eq "cross-key no-marker: exit 0" "0" "$exit_code"
    local after_sum; after_sum=$(cksum < "$repo/.test-index")
    assert_eq "cross-key no-marker: file unchanged" "$before_sum" "$after_sum"
    rm -rf "$repo"
}

# ── Test 804a-84c7c (RED): cross-key conflict detected even when no source-key dups ──
# The fast path (no source-key dups, no within-line marker dups) must still run the
# cross-key check and exit 1 when a marker conflict is found.
test_fast_path_rejects_cross_key_conflict() {
    local repo; repo=$(_make_fixture_repo)
    # Distinct source keys (no source-key dup), each with a different marker for
    # the same test file — pure cross-key conflict on a clean-looking file.
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/foo.sh [markerA],tests/a_only.sh
src/b.py:tests/foo.sh [markerB],tests/b_only.sh
EOF
    local exit_code=0
    ( cd "$repo" && bash "$GUARD" 2>/dev/null ) || exit_code=$?
    assert_eq "fast-path cross-key conflict: exit 1 (not 0)" "1" "$exit_code"
    rm -rf "$repo"
}

# ── Test 804a-84c7d (RED): cross-key conflict detected after auto-union resolves dups ──
# When source-key dups exist AND a cross-key marker conflict exists, the guard must
# first union the dups, then detect the cross-key conflict and exit 1.
test_post_union_cross_key_conflict_exits_1() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/shared.sh [markerA]
src/a.py:tests/a_extra.sh
src/b.py:tests/shared.sh [markerB]
EOF
    local exit_code=0
    local stderr_out
    stderr_out=$( cd "$repo" && bash "$GUARD" 2>&1 ) || exit_code=$?
    assert_eq "post-union cross-key conflict: exit 1" "1" "$exit_code"
    if [[ "$stderr_out" == *"tests/shared.sh"* ]]; then
        assert_eq "post-union cross-key conflict: error names conflicting file" "has-file" "has-file"
    else
        assert_eq "post-union cross-key conflict: error names conflicting file" "has-file" "missing: $stderr_out"
    fi
    rm -rf "$repo"
}

# ── Test f86e-6f23 (RED): non-runnable extension in test target rejected ──────
# A .test-index entry whose test target has a known non-runnable extension
# (e.g. .yaml, .yml, .json, .md, .conf, .txt) must be rejected with exit 1.
# These extensions can never be run as bash/python test files and indicate a
# misconfiguration (e.g. accidentally listing a semgrep rules config as a test).
test_rejects_yaml_test_target() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a.sh
plugins/dso/hooks/semgrep-rules/test-anti-patterns.yaml:tests/b.sh
src/b.py:plugins/dso/hooks/semgrep-rules/test-anti-patterns.yaml
EOF
    local exit_code=0
    local stderr_out
    stderr_out=$( cd "$repo" && bash "$GUARD" 2>&1 ) || exit_code=$?
    assert_eq "yaml test target: exit 1" "1" "$exit_code"
    if [[ "$stderr_out" == *".yaml"* ]] || [[ "$stderr_out" == *"non-runnable"* ]]; then
        assert_eq "yaml test target: error mentions .yaml or non-runnable" "has-msg" "has-msg"
    else
        assert_eq "yaml test target: error mentions .yaml or non-runnable" "has-msg" "missing: $stderr_out"
    fi
    rm -rf "$repo"
}

test_rejects_json_test_target() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a.sh,some/config.json
EOF
    local exit_code=0
    local stderr_out
    stderr_out=$( cd "$repo" && bash "$GUARD" 2>&1 ) || exit_code=$?
    assert_eq "json test target: exit 1" "1" "$exit_code"
    rm -rf "$repo"
}

test_rejects_md_test_target() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
plugins/dso/skills/retro/docs/reviewers/test-quality.md:plugins/dso/skills/retro/docs/reviewers/test-quality.md,tests/hooks/test-pre-commit-test-quality-gate.sh
EOF
    local exit_code=0
    local stderr_out
    stderr_out=$( cd "$repo" && bash "$GUARD" 2>&1 ) || exit_code=$?
    assert_eq "md test target: exit 1" "1" "$exit_code"
    rm -rf "$repo"
}

test_allows_valid_sh_and_py_test_targets() {
    local repo; repo=$(_make_fixture_repo)
    cat > "$repo/.test-index" <<'EOF'
src/a.py:tests/a.sh,tests/b_test.py
src/b.sh:tests/test_c.py
EOF
    local exit_code=0
    ( cd "$repo" && bash "$GUARD" ) || exit_code=$?
    assert_eq "valid sh/py targets: exit 0" "0" "$exit_code"
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
test_collapses_marker_only_duplicates_in_test_list
test_collapses_marker_only_dups_across_source_key_lines
test_rejects_cross_source_key_marker_conflict
test_allows_cross_source_key_no_marker_duplicate
test_fast_path_rejects_cross_key_conflict
test_post_union_cross_key_conflict_exits_1
test_rejects_yaml_test_target
test_rejects_json_test_target
test_rejects_md_test_target
test_allows_valid_sh_and_py_test_targets

print_summary
