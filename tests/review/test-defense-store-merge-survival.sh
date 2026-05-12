#!/usr/bin/env bash
# tests/review/test-defense-store-merge-survival.sh
# Behavioral tests for plugins/dso/scripts/review-defense-store.sh —
# defense records survive a story→session merge (attestation not stale-invalidated).
#
# Background: After a story branch is merged into a session branch, review may
# occur at the merge commit (HEAD of session). The defense_store_load_for_region
# function must return records whose SHA range (BASE..TIP) has commits that are
# ancestors of the merge commit — i.e., TIP is reachable from MERGE_COMMIT.
# Simply checking if MERGE_COMMIT ∈ ancestry-path(BASE..TIP) is insufficient:
# MERGE_COMMIT is a new commit not in BASE..TIP, so it would always be excluded.
# The correct check is: TIP ∈ ancestors(MERGE_COMMIT) — the range is still valid
# from the merged perspective.
#
# Tests:
#   1. test_defense_store_merge_survival — record IS returned when query_sha is
#      the merge commit and TIP is an ancestor of MERGE_COMMIT.
#      RED: current code checks if MERGE_COMMIT ∈ ancestry-path(BASE..TIP), which
#      is false (merge commit not in story range) — so current code wrongly excludes
#      the record.
#
#   2. test_defense_store_excludes_unrelated_sha — record is NOT returned when
#      query_sha is a commit that is completely unrelated (on a different branch,
#      not a descendant of TIP).
#      This tests that the merge-survival logic doesn't over-include records.
#
# Usage: bash tests/review/test-defense-store-merge-survival.sh
# Returns: exit 1 (RED) until merge-survival ancestry check is implemented.

# NOTE: -e intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-defense-store-merge-survival.sh ==="

# ---------------------------------------------------------------------------
# Helper: _build_ticket_json record_json
# Wraps a defense record JSON in a fake ticket JSON structure matching the
# shape that defense_store_load_for_region parses (ticket.comments[].body).
# ---------------------------------------------------------------------------
_build_ticket_json() {
    local record_json="$1"
    python3 -c "
import json, sys
record = sys.argv[1]
ticket = {
    'id': 'TEST-MERGE-TICKET-001',
    'title': 'merge survival test ticket',
    'comments': [
        {'body': 'DEFENSE_RECORD: ' + record}
    ]
}
print(json.dumps(ticket))
" "$record_json"
}

# ---------------------------------------------------------------------------
# Helper: _make_merge_git_repo tmpdir
# Initialises a git repo with the following structure:
#
#   main:  BASE ─────────────────── MERGE_COMMIT
#                \                 /
#   story:        ──────── TIP ───
#
# Specifically:
#   1. Create initial commit on main (BASE)
#   2. Create story branch from BASE, add TIP commit
#   3. Merge story branch back into main with --no-ff → MERGE_COMMIT
#   4. Add another commit on main AFTER merge (EXTRA, to create an unrelated SHA)
#
# After merge:
#   - TIP is an ancestor of MERGE_COMMIT (reachable from MERGE_COMMIT via first-parent)
#   - MERGE_COMMIT is NOT in git log --ancestry-path BASE..TIP (it's outside story range)
#   - EXTRA is NOT an ancestor of TIP (added after merge on main)
#
# Prints four SHAs space-separated: BASE TIP MERGE_COMMIT EXTRA
# ---------------------------------------------------------------------------
_make_merge_git_repo() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false

    # BASE commit on main
    echo "base" > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "base"
    local base_sha
    base_sha=$(git -C "$dir" rev-parse HEAD)

    # Create story branch from BASE
    git -C "$dir" checkout -q -b story/test-epic/test-story

    # TIP commit on story branch
    echo "story work" > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "story: implement feature"
    local tip_sha
    tip_sha=$(git -C "$dir" rev-parse HEAD)

    # Switch back to main and merge story branch (--no-ff creates a real merge commit)
    git -C "$dir" checkout -q main
    git -C "$dir" merge --no-ff -q story/test-epic/test-story -m "Merge story into main"
    local merge_sha
    merge_sha=$(git -C "$dir" rev-parse HEAD)

    # Add another commit on main AFTER the merge (unrelated to story range)
    echo "post-merge work" > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "post-merge: additional session work"
    local extra_sha
    extra_sha=$(git -C "$dir" rev-parse HEAD)

    printf '%s %s %s %s' "$base_sha" "$tip_sha" "$merge_sha" "$extra_sha"
}

# =============================================================================
# Test 1 — defense_store_load_for_region returns the record when query_sha is
#           the merge commit and the story TIP is an ancestor of that merge commit.
#
# RED rationale: The current implementation checks whether MERGE_COMMIT is in
# git log --ancestry-path BASE..TIP. MERGE_COMMIT was created AFTER TIP (as
# the merge parent) and is NOT in the BASE..TIP range — so the current code
# silently excludes the record. The correct behavior is to recognize that TIP
# is an ancestor of MERGE_COMMIT, meaning the story's review range covers the
# changes brought into MERGE_COMMIT, and the attestation remains valid.
#
# Given: story commits BASE→TIP merged into main → MERGE_COMMIT
#        defense record with story_branch_base_sha=BASE, story_branch_tip_sha=TIP
#        query_sha = MERGE_COMMIT
# When:  defense_store_load_for_region called with --query-sha MERGE_COMMIT
# Then:  record IS returned (TIP is an ancestor of MERGE_COMMIT → attestation valid)
#
# This will FAIL with current implementation (RED) because MERGE_COMMIT is not in
# the ancestry-path BASE..TIP range.
# =============================================================================
echo ""
echo "--- test_defense_store_merge_survival ---"

test_defense_store_merge_survival() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_merge_survival\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Build a temp git repo with a merge commit
    local tmpdir
    tmpdir=$(mktemp -d /tmp/dso-merge-test.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local shas
    shas=$(_make_merge_git_repo "$tmpdir")
    local base_sha tip_sha merge_sha extra_sha
    base_sha=$(printf '%s' "$shas" | awk '{print $1}')
    tip_sha=$(printf '%s' "$shas" | awk '{print $2}')
    merge_sha=$(printf '%s' "$shas" | awk '{print $3}')
    extra_sha=$(printf '%s' "$shas" | awk '{print $4}')

    # Verify test invariants before running
    # 1. TIP must be an ancestor of MERGE_COMMIT (reachable from merge)
    local tip_is_ancestor_of_merge
    tip_is_ancestor_of_merge=$(git -C "$tmpdir" merge-base --is-ancestor "$tip_sha" "$merge_sha" 2>/dev/null && echo "yes" || echo "no")
    if [[ "$tip_is_ancestor_of_merge" != "yes" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_merge_survival\n  test setup error: TIP is not an ancestor of MERGE_COMMIT\n  tip=%s merge=%s\n" \
            "$tip_sha" "$merge_sha" >&2
        return
    fi

    # 2. MERGE_COMMIT must NOT be in BASE..TIP ancestry (confirming it's the "new" scenario)
    local ancestry_list
    ancestry_list=$(git -C "$tmpdir" log --ancestry-path "${base_sha}..${tip_sha}" --format="%H" 2>/dev/null) || ancestry_list=""
    if printf '%s\n' "$ancestry_list" | grep -qxF "$merge_sha" 2>/dev/null; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_merge_survival\n  test setup error: MERGE_COMMIT unexpectedly in BASE..TIP ancestry\n  merge=%s\n" \
            "$merge_sha" >&2
        return
    fi

    # Build a defense record with SHA-range fields
    local record_json
    record_json=$(python3 -c "
import json
print(json.dumps({
    'prior_finding_id': 'f-merge-survival-1',
    'file_paths': ['src/feature.py'],
    'defense_text': 'defense that must survive story→session merge',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': '$tip_sha',
    'story_branch_base_sha': '$base_sha'
}))
")

    local ticket_json
    ticket_json=$(_build_ticket_json "$record_json")

    # Create a TICKET_CMD stub that returns the fake ticket JSON
    local stub_ticket_cmd
    stub_ticket_cmd=$(mktemp /tmp/dso-ticket-stub.XXXXXX)
    chmod +x "$stub_ticket_cmd"
    printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$ticket_json" > "$stub_ticket_cmd"

    # Call defense_store_load_for_region with:
    #   - query_sha = MERGE_COMMIT (TIP is an ancestor of this, but it's not IN BASE..TIP range)
    #   - region_files = src/feature.py (matches file_paths in record)
    #   - GIT_DIR pointed at the test repo
    local output
    # shellcheck disable=SC2030,SC2031
    output=$(
        export DSO_SESSION_TICKET_ID="TEST-MERGE-TICKET-001"
        export TICKET_CMD="$stub_ticket_cmd"
        export GIT_DIR="$tmpdir/.git"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load_for_region --query-sha "$merge_sha" "src/feature.py" 2>/dev/null
    ) || true

    rm -f "$stub_ticket_cmd"

    # The record MUST appear in output (TIP is ancestor of MERGE_COMMIT → attestation valid)
    # RED: current implementation checks MERGE_COMMIT ∈ ancestry-path(BASE..TIP) which is false
    local record_found=0
    if printf '%s\n' "$output" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == 'f-merge-survival-1':
            sys.exit(0)
    except (json.JSONDecodeError, ValueError):
        continue
sys.exit(1)
" 2>/dev/null; then
        record_found=1
    fi

    assert_eq "test_defense_store_merge_survival: record IS returned when query_sha is merge commit and TIP is its ancestor" \
        "1" "$record_found"

    assert_pass_if_clean "test_defense_store_merge_survival"
}

test_defense_store_merge_survival

# =============================================================================
# Test 2 — defense_store_load_for_region does NOT return a record when
#           query_sha is a commit that is NOT a descendant of TIP at all.
#
# Given: same git repo
#        defense record with story_branch_base_sha=BASE, story_branch_tip_sha=TIP
#        query_sha = EXTRA (a session commit made after merge, not related to TIP
#                           in the sense that it's a grandchild, so this should
#                           actually STILL be a descendant of TIP via MERGE_COMMIT)
# Note: EXTRA is a descendant of TIP (EXTRA → MERGE_COMMIT → TIP). To create a
#       truly unrelated SHA, we need a different test structure. Use an orphan
#       branch commit as the unrelated SHA.
#
# Strategy: create an orphan branch commit with no shared ancestry → that SHA
# is truly unrelated to the story range.
#
# Given: query_sha = orphan commit (no shared history with story)
# When:  defense_store_load_for_region called with --query-sha <orphan_sha>
# Then:  record is NOT returned (orphan is not a descendant of TIP)
# =============================================================================
echo ""
echo "--- test_defense_store_excludes_unrelated_sha ---"

test_defense_store_excludes_unrelated_sha() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_excludes_unrelated_sha\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Build a temp git repo with a merge commit
    local tmpdir
    tmpdir=$(mktemp -d /tmp/dso-merge-test.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local shas
    shas=$(_make_merge_git_repo "$tmpdir")
    local base_sha tip_sha merge_sha
    base_sha=$(printf '%s' "$shas" | awk '{print $1}')
    tip_sha=$(printf '%s' "$shas" | awk '{print $2}')
    merge_sha=$(printf '%s' "$shas" | awk '{print $3}')

    # Create an orphan commit: a commit with no shared ancestry with the story range
    git -C "$tmpdir" checkout -q --orphan unrelated-branch
    git -C "$tmpdir" rm -rf . -q 2>/dev/null || true
    echo "unrelated content" > "$tmpdir/unrelated.txt"
    git -C "$tmpdir" add unrelated.txt
    git -C "$tmpdir" commit -q -m "unrelated orphan commit"
    local unrelated_sha
    unrelated_sha=$(git -C "$tmpdir" rev-parse HEAD)

    # Verify test invariant: unrelated_sha is NOT a descendant of TIP
    local tip_is_ancestor_of_unrelated
    tip_is_ancestor_of_unrelated=$(git -C "$tmpdir" merge-base --is-ancestor "$tip_sha" "$unrelated_sha" 2>/dev/null && echo "yes" || echo "no")
    if [[ "$tip_is_ancestor_of_unrelated" == "yes" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_excludes_unrelated_sha\n  test setup error: TIP unexpectedly IS an ancestor of unrelated_sha\n  tip=%s unrelated=%s\n" \
            "$tip_sha" "$unrelated_sha" >&2
        return
    fi

    # Build a defense record with SHA-range fields
    local record_json
    record_json=$(python3 -c "
import json
print(json.dumps({
    'prior_finding_id': 'f-merge-unrelated-1',
    'file_paths': ['src/feature.py'],
    'defense_text': 'defense that should not match unrelated orphan sha',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': '$tip_sha',
    'story_branch_base_sha': '$base_sha'
}))
")

    local ticket_json
    ticket_json=$(_build_ticket_json "$record_json")

    # Create a TICKET_CMD stub that returns the fake ticket JSON
    local stub_ticket_cmd
    stub_ticket_cmd=$(mktemp /tmp/dso-ticket-stub.XXXXXX)
    chmod +x "$stub_ticket_cmd"
    printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$ticket_json" > "$stub_ticket_cmd"

    # Call defense_store_load_for_region with:
    #   - query_sha = unrelated_sha (orphan, not a descendant of TIP)
    #   - region_files = src/feature.py (matches file_paths in record)
    local output
    # shellcheck disable=SC2030,SC2031
    output=$(
        export DSO_SESSION_TICKET_ID="TEST-MERGE-TICKET-001"
        export TICKET_CMD="$stub_ticket_cmd"
        export GIT_DIR="$tmpdir/.git"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load_for_region --query-sha "$unrelated_sha" "src/feature.py" 2>/dev/null
    ) || true

    rm -f "$stub_ticket_cmd"

    # The record must NOT appear in output (orphan commit is not a descendant of TIP)
    local record_found=0
    if printf '%s\n' "$output" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == 'f-merge-unrelated-1':
            sys.exit(0)
    except (json.JSONDecodeError, ValueError):
        continue
sys.exit(1)
" 2>/dev/null; then
        record_found=1
    fi

    assert_eq "test_defense_store_excludes_unrelated_sha: record is NOT returned when query_sha is an orphan commit (not descendant of TIP)" \
        "0" "$record_found"

    assert_pass_if_clean "test_defense_store_excludes_unrelated_sha"
}

test_defense_store_excludes_unrelated_sha

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
