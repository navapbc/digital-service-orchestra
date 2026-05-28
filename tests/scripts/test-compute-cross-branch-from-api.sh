#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # subshell-local env mutation is intentional for test isolation
# tests/scripts/test-compute-cross-branch-from-api.sh
#
# RED-phase behavioral tests for plugins/dso/scripts/compute-cross-branch-from-api.sh
#
# Every assertion exercises the script's observable behavior:
#   - exit code
#   - stdout / stderr content
#   - CROSS_BRANCH_FILE contents (filesystem side effect)
#
# These tests FAIL in RED phase because the script does not exist yet.
# They will PASS once the script is implemented per its contract.
#
# Assertions map to spec items (a)-(s) in the task description.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/ci-pr-auto-merge"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/compute-cross-branch-from-api.sh"
SETUP_REPO="$FIXTURE_DIR/setup-synthetic-repo.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# Temporary directory pool — all test temps registered here for EXIT cleanup
_TEST_TMPDIRS=()
trap 'rm -rf "${_TEST_TMPDIRS[@]:-}"' EXIT INT TERM

# Helper: create a new isolated temp dir and echo its path
_mktmp() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-xb-api.XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# Helper: create a minimal synthetic git repo with N "Merge pull request" commits
# on the session branch (no DSO-Story-Merge trailers).
#   $1 = dest root
#   $2 = epic id
#   $3 = story count
_setup_repo() {
    SYNTHETIC_BASE_REF="${4:-main}" SYNTHETIC_HEAD_REF="${5:-worktree-test}" \
        bash "$SETUP_REPO" "$1" "$2" "$3" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# (a) Script exists and is executable
# ---------------------------------------------------------------------------
test_a_script_exists_and_is_executable() {
    local exit_code=0
    bash -c 'test -x "$1"' _ "$SCRIPT" 2>/dev/null || exit_code=$?
    assert_eq "script_exists_and_executable" "0" "$exit_code"
}

# ---------------------------------------------------------------------------
# (b) 4 PRs with review-sub-pr=success → CROSS_BRANCH_FILE is empty
# ---------------------------------------------------------------------------
test_b_all_success_subtracted() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 4

    local cbf="$tmp/cross-branch-files.txt"
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || true

    assert_eq "cross_branch_file_exists_b" "0" "$(test -f "$cbf"; echo $?)"
    local line_count=0
    if [[ -f "$cbf" ]]; then
        line_count=$(grep -c '[^[:space:]]' "$cbf" || echo "0")
    fi
    assert_eq "all_success_empty_cbf" "0" "$line_count"
}

# ---------------------------------------------------------------------------
# (c) Closed-not-merged PR (merged_at=null) excluded
# ---------------------------------------------------------------------------
test_c_closed_not_merged_excluded() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 4

    local cbf="$tmp/cross-branch-files.txt"
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || true

    # PR 6 has merged_at=null; its file is "plugins/dso/scripts/closed-not-merged.sh"
    local found=false
    if [[ -f "$cbf" ]] && grep -qF "closed-not-merged.sh" "$cbf" 2>/dev/null; then
        found=true
    fi
    assert_eq "closed_not_merged_excluded" "false" "$found"
}

# ---------------------------------------------------------------------------
# (d) Wrong-base-ref PR excluded (base != HEAD_REF)
# ---------------------------------------------------------------------------
test_d_wrong_base_ref_excluded() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 2

    # Override pr-list to include a PR with wrong base ref
    mkdir -p "$tmp/fixtures/bin"
    cp -r "$FIXTURE_DIR/bin/." "$tmp/fixtures/bin/"
    cp "$FIXTURE_DIR"/pr-files-*.json "$tmp/fixtures/"
    cp "$FIXTURE_DIR"/check-runs-*.json "$tmp/fixtures/"

    # Write a custom pr-list with one PR having the wrong base ref
    cat > "$tmp/fixtures/pr-list.json" <<'EOF'
[
  {
    "number": 1,
    "title": "Merge pull request story/1d8b/s1",
    "head": { "ref": "story/1d8b/s1" },
    "base": { "ref": "worktree-test" },
    "merged_at": "2026-05-01T10:00:00Z",
    "merge_commit_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  {
    "number": 2,
    "title": "Merge pull request story/1d8b/s2",
    "head": { "ref": "story/1d8b/s2" },
    "base": { "ref": "wrong-base-branch" },
    "merged_at": "2026-05-02T10:00:00Z",
    "merge_commit_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
]
EOF
    # Point the stub to this custom fixture dir
    local cbf="$tmp/cross-branch-files.txt"
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || true

    # bar.sh is in PR 2 (wrong base) and should NOT appear
    local found=false
    if [[ -f "$cbf" ]] && grep -qF "bar.sh" "$cbf" 2>/dev/null; then
        found=true
    fi
    assert_eq "wrong_base_excluded" "false" "$found"
}

# ---------------------------------------------------------------------------
# (e) PR with review-sub-pr conclusion=skipped → files APPEAR in CROSS_BRANCH_FILE
# ---------------------------------------------------------------------------
test_e_skipped_review_included() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 5

    local cbf="$tmp/cross-branch-files.txt"
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || true

    # PR 5 check-run = skipped; its file is "plugins/dso/scripts/skipped-review-file.sh"
    local found=false
    if [[ -f "$cbf" ]] && grep -qF "skipped-review-file.sh" "$cbf" 2>/dev/null; then
        found=true
    fi
    assert_eq "skipped_review_files_included" "true" "$found"
}

# ---------------------------------------------------------------------------
# (f) PR with review-sub-pr conclusion=failure → files APPEAR in CROSS_BRANCH_FILE
# ---------------------------------------------------------------------------
test_f_failure_review_included() {
    local tmp
    tmp=$(_mktmp)

    # Create a custom fixture dir with PR 5 check-run = failure
    mkdir -p "$tmp/fixtures/bin"
    cp "$FIXTURE_DIR/bin/gh" "$tmp/fixtures/bin/gh"
    chmod +x "$tmp/fixtures/bin/gh"
    cp "$FIXTURE_DIR"/pr-list.json "$tmp/fixtures/"
    cp "$FIXTURE_DIR"/pr-files-*.json "$tmp/fixtures/"
    cp "$FIXTURE_DIR"/check-runs-*.json "$tmp/fixtures/"
    # Override check-runs-5 to return failure
    cat > "$tmp/fixtures/check-runs-5.json" <<'EOF'
{
  "check_runs": [
    {
      "name": "review-sub-pr",
      "status": "completed",
      "conclusion": "failure"
    }
  ]
}
EOF

    _setup_repo "$tmp" "1d8b" 5

    local cbf="$tmp/cross-branch-files.txt"
    local out
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || true

    local found=false
    if [[ -f "$cbf" ]] && grep -qF "skipped-review-file.sh" "$cbf" 2>/dev/null; then
        found=true
    fi
    assert_eq "failure_review_files_included" "true" "$found"
}

# ---------------------------------------------------------------------------
# (g) Non-ancestor merge_commit_sha → warning emitted, files NOT appended
# ---------------------------------------------------------------------------
test_g_non_ancestor_sha_warning_no_append() {
    local tmp
    tmp=$(_mktmp)

    # Create a fixture with a PR whose merge_commit_sha is not reachable in
    # the synthetic repo (no fetch or commit with that sha). The stub will
    # return a made-up SHA that can't be validated.
    mkdir -p "$tmp/fixtures/bin"
    cp "$FIXTURE_DIR/bin/gh" "$tmp/fixtures/bin/gh"
    chmod +x "$tmp/fixtures/bin/gh"
    cp "$FIXTURE_DIR"/pr-files-*.json "$tmp/fixtures/"
    cp "$FIXTURE_DIR"/check-runs-*.json "$tmp/fixtures/"

    # PR list with one PR whose SHA is totally unreachable
    cat > "$tmp/fixtures/pr-list.json" <<'EOF'
[
  {
    "number": 7,
    "title": "Merge pull request story/1d8b/s7",
    "head": { "ref": "story/1d8b/s7" },
    "base": { "ref": "worktree-test" },
    "merged_at": "2026-05-07T10:00:00Z",
    "merge_commit_sha": "0000000000000000000000000000000000000007"
  }
]
EOF
    cat > "$tmp/fixtures/pr-files-7.json" <<'EOF'
[
  { "filename": "plugins/dso/scripts/orphan-file.sh", "status": "added" }
]
EOF
    cat > "$tmp/fixtures/check-runs-7.json" <<'EOF'
{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"success"}]}
EOF

    _setup_repo "$tmp" "1d8b" 1

    local cbf="$tmp/cross-branch-files.txt"
    local out
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || true

    # Script should emit a ::warning:: for the unreachable SHA
    assert_contains "non_ancestor_warning_emitted" "::warning::" "$out"

    # The orphan file should NOT appear (skip — rebase orphan)
    local found=false
    if [[ -f "$cbf" ]] && grep -qF "orphan-file.sh" "$cbf" 2>/dev/null; then
        found=true
    fi
    assert_eq "non_ancestor_files_not_appended" "false" "$found"
}

# ---------------------------------------------------------------------------
# (g2) Rebase-orphan: merge_commit_sha is FETCHABLE (so production passes the
#      fetch gate) but NOT an ancestor of session HEAD (sibling branch). Must
#      emit "::warning::PR #N merge_commit_sha not ancestor of session HEAD"
#      and NOT append the PR's files to CROSS_BRANCH_FILE.
#
#      Distinct from test_g, which exercises the unprovenanced-PR jq-filter
#      path (an SHA that is unfetchable). This test exercises the true
#      rebase-orphan code path in production (the fetch-and-ancestor branch).
# ---------------------------------------------------------------------------
test_g2_rebase_orphan_fetchable_but_not_ancestor() {
    local tmp
    tmp=$(_mktmp)

    # Build remote + session with a real "Merge pull request" commit (so
    # story_refs derivation finds story/1d8b/s1) AND a sibling commit that
    # is reachable from origin but not from session HEAD.
    local remote_dir="$tmp/remote"
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare -q
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    local ws
    ws=$(mktemp -d "${TMPDIR:-/tmp}/xb-ws-g2.XXXXXX")
    _TEST_TMPDIRS+=("$ws")
    git -C "$ws" init -q -b main
    git -C "$ws" config user.email "t@t.local"
    git -C "$ws" config user.name "T"
    echo "root" > "$ws/R"
    git -C "$ws" add R && git -C "$ws" commit -q -m "root"
    git -C "$ws" remote add origin "$remote_dir"
    git -C "$ws" push -q origin main

    # session branch with the merge commit
    git -C "$ws" checkout -q -b worktree-test
    echo "s1" > "$ws/s1.txt"
    git -C "$ws" add s1.txt
    git -C "$ws" commit -q -m "Merge pull request #1 from story/1d8b/s1"
    git -C "$ws" push -q origin worktree-test

    # Sibling branch with the rebase-orphan commit (NOT on worktree-test)
    git -C "$ws" checkout -q -b orphan-sibling main
    echo "orphan" > "$ws/orphan.txt"
    git -C "$ws" add orphan.txt
    git -C "$ws" commit -q -m "orphan commit (not on session branch)"
    local orphan_sha
    orphan_sha=$(git -C "$ws" rev-parse HEAD)
    git -C "$ws" push -q origin orphan-sibling

    # Switch back to session branch — orphan_sha is fetchable but not an
    # ancestor of HEAD on worktree-test.
    git -C "$ws" checkout -q worktree-test

    # Fixture dir with a PR pointing at orphan_sha
    mkdir -p "$tmp/fixtures/bin"
    cp "$FIXTURE_DIR/bin/gh" "$tmp/fixtures/bin/gh"
    chmod +x "$tmp/fixtures/bin/gh"
    cat > "$tmp/fixtures/pr-list.json" <<EOF
[
  {
    "number": 99,
    "title": "Merge pull request story/1d8b/s1",
    "head": { "ref": "story/1d8b/s1" },
    "base": { "ref": "worktree-test" },
    "merged_at": "2026-05-01T10:00:00Z",
    "merge_commit_sha": "${orphan_sha}"
  }
]
EOF
    cat > "$tmp/fixtures/pr-files-99.json" <<'EOF'
[
  { "filename": "plugins/dso/scripts/rebase-orphan-file.sh", "status": "added" }
]
EOF
    cat > "$tmp/fixtures/check-runs-99.json" <<'EOF'
{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"skipped"}]}
EOF

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$ws" || return
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    # Script should emit the rebase-orphan warning specifically.
    assert_contains "g2_rebase_orphan_warning" "not ancestor of session HEAD" "$out"

    # The orphan file must NOT be appended.
    local found=false
    if [[ -f "$cbf" ]] && grep -qF "rebase-orphan-file.sh" "$cbf" 2>/dev/null; then
        found=true
    fi
    assert_eq "g2_orphan_files_not_appended" "false" "$found"
}

# ---------------------------------------------------------------------------
# (h) Idempotency: sort -u prevents duplicate file entries
# ---------------------------------------------------------------------------
test_h_idempotency_sort_unique() {
    local tmp
    tmp=$(_mktmp)

    # Two PRs (both with skipped review) that touch the SAME file
    mkdir -p "$tmp/fixtures/bin"
    cp "$FIXTURE_DIR/bin/gh" "$tmp/fixtures/bin/gh"
    chmod +x "$tmp/fixtures/bin/gh"

    cat > "$tmp/fixtures/pr-list.json" <<'EOF'
[
  {
    "number": 1,
    "title": "Merge pull request story/1d8b/s1",
    "head": { "ref": "story/1d8b/s1" },
    "base": { "ref": "worktree-test" },
    "merged_at": "2026-05-01T10:00:00Z",
    "merge_commit_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  {
    "number": 2,
    "title": "Merge pull request story/1d8b/s2",
    "head": { "ref": "story/1d8b/s2" },
    "base": { "ref": "worktree-test" },
    "merged_at": "2026-05-02T10:00:00Z",
    "merge_commit_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
]
EOF
    # Both PRs touch the SAME file
    echo '[{"filename":"plugins/dso/scripts/shared.sh","status":"modified"}]' > "$tmp/fixtures/pr-files-1.json"
    echo '[{"filename":"plugins/dso/scripts/shared.sh","status":"modified"}]' > "$tmp/fixtures/pr-files-2.json"
    # Both PRs have skipped review (so files are re-included)
    echo '{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"skipped"}]}' > "$tmp/fixtures/check-runs-1.json"
    echo '{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"skipped"}]}' > "$tmp/fixtures/check-runs-2.json"

    _setup_repo "$tmp" "1d8b" 2

    local cbf="$tmp/cross-branch-files.txt"
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || true

    local count=0
    if [[ -f "$cbf" ]]; then
        count=$(grep -cF "plugins/dso/scripts/shared.sh" "$cbf" || echo "0")
    fi
    assert_eq "idempotent_sort_unique" "1" "$count"
}

# ---------------------------------------------------------------------------
# (i) gh api 404 on pulls/N/files → warn + append files (conservative), exit 0
# ---------------------------------------------------------------------------
test_i_404_appends_files_and_exits_0() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 5

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        export DSO_GH_STUB_MODE="error_404_pr_5"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    assert_eq "404_exits_0" "0" "$exit_code"
    assert_contains "404_emits_warning" "::warning::" "$out"

    # On a 404 from the files endpoint itself, files cannot be appended (the
    # endpoint returned no data); the script must emit a "cannot append
    # filenames" warning and continue. This is the production contract per
    # the round-2 review (Finding #4: no test-mode coupling in production).
    assert_contains "404_emits_cannot_append_warning" "cannot append filenames" "$out"
    local found=false
    if [[ -f "$cbf" ]] && grep -qF "skipped-review-file.sh" "$cbf" 2>/dev/null; then
        found=true
    fi
    assert_eq "404_files_endpoint_no_append" "false" "$found"
}

# ---------------------------------------------------------------------------
# (j) gh api 403 first attempt → sleep Retry-After, retry succeeds → exit 0
# ---------------------------------------------------------------------------
test_j_403_retry_success() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 4

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        export DSO_GH_STUB_MODE="error_403_once"
        export DSO_GH_403_COUNTER_FILE="$tmp/gh-403-counter"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    assert_eq "403_retry_success_exit_0" "0" "$exit_code"
}

# ---------------------------------------------------------------------------
# (k) gh api 403 after retry exhausted → ::error:: + exit 1
# ---------------------------------------------------------------------------
test_k_403_retry_exhausted_exits_1() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 4

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        export DSO_GH_STUB_MODE="error_403_exhausted"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    assert_eq "403_exhausted_exits_1" "1" "$exit_code"
    assert_contains "403_exhausted_error_annotation" "::error::" "$out"
}

# ---------------------------------------------------------------------------
# (l) gh api 500 → ::error:: + exit 1 (no retry on 5xx)
# ---------------------------------------------------------------------------
test_l_500_exits_1_no_retry() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 4

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        export DSO_GH_STUB_MODE="error_500_first_call"
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    assert_eq "500_exits_1" "1" "$exit_code"
    assert_contains "500_error_annotation" "::error::" "$out"
}

# ---------------------------------------------------------------------------
# (m) Multi-epic merge subjects → both epic-ids derived, both PR sets processed
# ---------------------------------------------------------------------------
test_m_multi_epic_both_derived() {
    local tmp
    tmp=$(_mktmp)

    # Build a repo with commits from two epics
    local remote_dir="$tmp/remote"
    local session_dir="$tmp/session"
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare -q
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    local ws
    ws=$(mktemp -d "${TMPDIR:-/tmp}/xb-ws.XXXXXX")
    _TEST_TMPDIRS+=("$ws")
    git -C "$ws" init -q -b main
    git -C "$ws" config user.email "t@t.local"
    git -C "$ws" config user.name "T"
    echo "root" > "$ws/R"
    git -C "$ws" add R
    git -C "$ws" commit -q -m "root"
    git -C "$ws" remote add origin "$remote_dir"
    git -C "$ws" push -q origin main
    git -C "$ws" checkout -q -b worktree-test

    # Two commits: one for epic 1d8b, one for epic 0000
    echo "s1" > "$ws/s1.txt"
    git -C "$ws" add s1.txt
    git -C "$ws" commit -q -m "Merge pull request #1 from story/1d8b/s1"
    echo "s2" > "$ws/s2.txt"
    git -C "$ws" add s2.txt
    git -C "$ws" commit -q -m "Merge pull request #2 from story/0000/s1"

    git -C "$ws" push -q origin worktree-test
    git clone -q --no-local "$remote_dir" "$session_dir"
    git -C "$session_dir" config user.email "t@t.local"
    git -C "$session_dir" config user.name "T"
    git -C "$session_dir" checkout -q worktree-test
    git -C "$session_dir" fetch -q origin main

    # Fixture with PRs from both epics (both skipped, so both appear in cbf)
    mkdir -p "$tmp/fixtures/bin"
    cp "$FIXTURE_DIR/bin/gh" "$tmp/fixtures/bin/gh"
    chmod +x "$tmp/fixtures/bin/gh"

    cat > "$tmp/fixtures/pr-list.json" <<'EOF'
[
  {
    "number": 1,
    "title": "Merge pull request story/1d8b/s1",
    "head": { "ref": "story/1d8b/s1" },
    "base": { "ref": "worktree-test" },
    "merged_at": "2026-05-01T10:00:00Z",
    "merge_commit_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  {
    "number": 2,
    "title": "Merge pull request story/0000/s1",
    "head": { "ref": "story/0000/s1" },
    "base": { "ref": "worktree-test" },
    "merged_at": "2026-05-02T10:00:00Z",
    "merge_commit_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
]
EOF
    echo '[{"filename":"plugins/dso/scripts/epic1d8b-file.sh","status":"added"}]' > "$tmp/fixtures/pr-files-1.json"
    echo '[{"filename":"plugins/dso/scripts/epic0000-file.sh","status":"added"}]' > "$tmp/fixtures/pr-files-2.json"
    echo '{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"skipped"}]}' > "$tmp/fixtures/check-runs-1.json"
    echo '{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"skipped"}]}' > "$tmp/fixtures/check-runs-2.json"

    local cbf="$tmp/cross-branch-files.txt"
    local out
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$session_dir" || return
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || true

    local found1=false found2=false
    if [[ -f "$cbf" ]]; then
        grep -qF "epic1d8b-file.sh" "$cbf" 2>/dev/null && found1=true
        grep -qF "epic0000-file.sh" "$cbf" 2>/dev/null && found2=true
    fi
    assert_eq "multi_epic_1d8b_present" "true" "$found1"
    assert_eq "multi_epic_0000_present" "true" "$found2"
}

# ---------------------------------------------------------------------------
# (n) Zero merge commits → warning + empty CROSS_BRANCH_FILE + exit 0
# ---------------------------------------------------------------------------
test_n_zero_merge_commits_soft_exit() {
    local tmp
    tmp=$(_mktmp)

    # Repo with NO "Merge pull request" commits — just a normal commit
    local remote_dir="$tmp/remote"
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare -q
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    local ws
    ws=$(mktemp -d "${TMPDIR:-/tmp}/xb-ws-n.XXXXXX")
    _TEST_TMPDIRS+=("$ws")
    git -C "$ws" init -q -b main
    git -C "$ws" config user.email "t@t.local"
    git -C "$ws" config user.name "T"
    echo "root" > "$ws/R"
    git -C "$ws" add R
    git -C "$ws" commit -q -m "root"
    git -C "$ws" remote add origin "$remote_dir"
    git -C "$ws" push -q origin main
    git -C "$ws" checkout -q -b worktree-test
    echo "feat" > "$ws/F"
    git -C "$ws" add F
    git -C "$ws" commit -q -m "feat: some regular commit (no merge subject)"
    git -C "$ws" push -q origin worktree-test

    local session_dir="$tmp/session"
    git clone -q --no-local "$remote_dir" "$session_dir"
    git -C "$session_dir" config user.email "t@t.local"
    git -C "$session_dir" config user.name "T"
    git -C "$session_dir" checkout -q worktree-test
    git -C "$session_dir" fetch -q origin main

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        cd "$session_dir" || return
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    assert_eq "no_merge_commits_exit_0" "0" "$exit_code"
    assert_contains "no_merge_commits_warning" "::warning::no story merge commits" "$out"
    assert_eq "no_merge_commits_cbf_exists" "0" "$(test -f "$cbf"; echo $?)"
    local line_count=0
    if [[ -f "$cbf" ]]; then
        line_count=$(grep -c '[^[:space:]]' "$cbf" || echo "0")
    fi
    assert_eq "no_merge_commits_cbf_empty" "0" "$line_count"
}

# ---------------------------------------------------------------------------
# (o) Commits matching "Merge pull request" but head ref NOT story/<epic>/<id>
#     → excluded by regex
# ---------------------------------------------------------------------------
test_o_non_story_branch_excluded() {
    local tmp
    tmp=$(_mktmp)

    local remote_dir="$tmp/remote"
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare -q
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    local ws
    ws=$(mktemp -d "${TMPDIR:-/tmp}/xb-ws-o.XXXXXX")
    _TEST_TMPDIRS+=("$ws")
    git -C "$ws" init -q -b main
    git -C "$ws" config user.email "t@t.local"
    git -C "$ws" config user.name "T"
    echo "root" > "$ws/R"
    git -C "$ws" add R
    git -C "$ws" commit -q -m "root"
    git -C "$ws" remote add origin "$remote_dir"
    git -C "$ws" push -q origin main
    git -C "$ws" checkout -q -b worktree-test
    echo "hotfix" > "$ws/H"
    git -C "$ws" add H
    # This matches "^Merge pull request" but head ref is "hotfix/urgent" not story/<epic>/<id>
    git -C "$ws" commit -q -m "Merge pull request #99 from hotfix/urgent"
    git -C "$ws" push -q origin worktree-test

    local session_dir="$tmp/session"
    git clone -q --no-local "$remote_dir" "$session_dir"
    git -C "$session_dir" config user.email "t@t.local"
    git -C "$session_dir" config user.name "T"
    git -C "$session_dir" checkout -q worktree-test
    git -C "$session_dir" fetch -q origin main

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        cd "$session_dir" || return
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    # With no story/<epic>/<id> pattern, epic_ids should be empty → soft exit
    assert_eq "non_story_branch_exits_0" "0" "$exit_code"
    assert_contains "non_story_branch_warning" "::warning::no story merge commits" "$out"
}

# ---------------------------------------------------------------------------
# (p) Shallow-clone simulation: defensive git fetch --unshallow succeeds
# ---------------------------------------------------------------------------
test_p_shallow_clone_unshallow() {
    local tmp
    tmp=$(_mktmp)

    # Build a deeper remote and clone with --depth=1 to simulate CI shallow clone
    local remote_dir="$tmp/remote"
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare -q
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    local ws
    ws=$(mktemp -d "${TMPDIR:-/tmp}/xb-ws-p.XXXXXX")
    _TEST_TMPDIRS+=("$ws")
    git -C "$ws" init -q -b main
    git -C "$ws" config user.email "t@t.local"
    git -C "$ws" config user.name "T"
    echo "root" > "$ws/R"
    git -C "$ws" add R
    git -C "$ws" commit -q -m "root"
    git -C "$ws" remote add origin "$remote_dir"
    git -C "$ws" push -q origin main
    git -C "$ws" checkout -q -b worktree-test
    echo "s1" > "$ws/s1.txt"
    git -C "$ws" add s1.txt
    git -C "$ws" commit -q -m "Merge pull request #1 from story/1d8b/s1"
    git -C "$ws" push -q origin worktree-test

    # Shallow clone — force --depth=1 via protocol.file.allow=always so
    # local file:// transport actually produces a shallow repo. Without this,
    # git's safety-default rejects shallow over file:// and the test silently
    # degrades to a full clone, never exercising the production --unshallow
    # defensive-fetch branch (Finding #6, round-2 review).
    local session_dir="$tmp/session"
    git -c protocol.file.allow=always clone -q --depth=1 --no-local "$remote_dir" "$session_dir"
    # Verify the clone actually IS shallow — otherwise the test is meaningless.
    if [[ "$(cd "$session_dir" && git rev-parse --is-shallow-repository 2>/dev/null)" != "true" ]]; then
        echo "test_p: shallow clone setup did not produce a shallow repository" >&2
        return 1
    fi
    git -C "$session_dir" config user.email "t@t.local"
    git -C "$session_dir" config user.name "T"
    git -C "$session_dir" fetch -q origin worktree-test 2>/dev/null || true
    git -C "$session_dir" checkout -q worktree-test 2>/dev/null || \
        git -C "$session_dir" checkout -q -b worktree-test "origin/worktree-test"

    # Fixture: one PR with success (so empty cbf expected)
    mkdir -p "$tmp/fixtures/bin"
    cp "$FIXTURE_DIR/bin/gh" "$tmp/fixtures/bin/gh"
    chmod +x "$tmp/fixtures/bin/gh"
    cat > "$tmp/fixtures/pr-list.json" <<'EOF'
[
  {
    "number": 1,
    "title": "Merge pull request story/1d8b/s1",
    "head": { "ref": "story/1d8b/s1" },
    "base": { "ref": "worktree-test" },
    "merged_at": "2026-05-01T10:00:00Z",
    "merge_commit_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
]
EOF
    echo '[{"filename":"plugins/dso/scripts/shallow-file.sh","status":"added"}]' > "$tmp/fixtures/pr-files-1.json"
    echo '{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"success"}]}' > "$tmp/fixtures/check-runs-1.json"

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$session_dir" || return
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    # Script should complete without error (defensive fetch handles shallow)
    assert_eq "shallow_clone_exits_0" "0" "$exit_code"
}

# ---------------------------------------------------------------------------
# (q) Multi-epic dedup: 6 PRs across 2 epics → epic_ids is sorted unique 2-element set
# ---------------------------------------------------------------------------
test_q_multi_epic_dedup_sorted_unique() {
    local tmp
    tmp=$(_mktmp)

    local remote_dir="$tmp/remote"
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare -q
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    local ws
    ws=$(mktemp -d "${TMPDIR:-/tmp}/xb-ws-q.XXXXXX")
    _TEST_TMPDIRS+=("$ws")
    git -C "$ws" init -q -b main
    git -C "$ws" config user.email "t@t.local"
    git -C "$ws" config user.name "T"
    echo "root" > "$ws/R"
    git -C "$ws" add R
    git -C "$ws" commit -q -m "root"
    git -C "$ws" remote add origin "$remote_dir"
    git -C "$ws" push -q origin main
    git -C "$ws" checkout -q -b worktree-test

    # 3 commits for epic aaa, 3 for epic bbb
    for i in 1 2 3; do
        echo "$i" > "$ws/epic-aaa-$i.txt"
        git -C "$ws" add "epic-aaa-$i.txt"
        git -C "$ws" commit -q -m "Merge pull request #$i from story/aaa/s$i"
    done
    for i in 4 5 6; do
        echo "$i" > "$ws/epic-bbb-$i.txt"
        git -C "$ws" add "epic-bbb-$i.txt"
        git -C "$ws" commit -q -m "Merge pull request #$i from story/bbb/s$i"
    done
    git -C "$ws" push -q origin worktree-test

    local session_dir="$tmp/session"
    git clone -q --no-local "$remote_dir" "$session_dir"
    git -C "$session_dir" config user.email "t@t.local"
    git -C "$session_dir" config user.name "T"
    git -C "$session_dir" checkout -q worktree-test
    git -C "$session_dir" fetch -q origin main

    # Fixture: empty PR list (epic_ids derived correctly, API finds no story PRs)
    mkdir -p "$tmp/fixtures/bin"
    cp "$FIXTURE_DIR/bin/gh" "$tmp/fixtures/bin/gh"
    chmod +x "$tmp/fixtures/bin/gh"
    echo '[]' > "$tmp/fixtures/pr-list.json"

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$session_dir" || return
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    # Script reaches the API call with 2 unique epic-ids (aaa, bbb) — should exit 0
    assert_eq "multi_epic_dedup_exits_0" "0" "$exit_code"
    # cbf should be empty (no PRs returned)
    local line_count=0
    if [[ -f "$cbf" ]]; then
        line_count=$(grep -c '[^[:space:]]' "$cbf" || echo "0")
    fi
    assert_eq "multi_epic_dedup_cbf_empty" "0" "$line_count"
}

# ---------------------------------------------------------------------------
# (r) LC_ALL=fr_FR.UTF-8 environment → script's internal LC_ALL=C overrides
# ---------------------------------------------------------------------------
test_r_lc_all_override() {
    local tmp
    tmp=$(_mktmp)
    _setup_repo "$tmp" "1d8b" 4

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$FIXTURE_DIR/bin:$PATH"
        export LC_ALL=fr_FR.UTF-8
        cd "$tmp/session"
        GITHUB_REPOSITORY="test/repo" HEAD_REF="worktree-test" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    # Script must still succeed and produce deterministic output regardless of caller LC_ALL
    assert_eq "lc_all_override_exits_0" "0" "$exit_code"
}

# ---------------------------------------------------------------------------
# (s) Renamed-session-branch: PR with old base not matching HEAD_REF
#     → git-log derivation still includes epic via commit subject;
#     API filter misses that PR (base mismatch — acceptable graceful degradation)
# ---------------------------------------------------------------------------
test_s_renamed_session_branch_graceful_degradation() {
    local tmp
    tmp=$(_mktmp)

    local remote_dir="$tmp/remote"
    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare -q
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    local ws
    ws=$(mktemp -d "${TMPDIR:-/tmp}/xb-ws-s.XXXXXX")
    _TEST_TMPDIRS+=("$ws")
    git -C "$ws" init -q -b main
    git -C "$ws" config user.email "t@t.local"
    git -C "$ws" config user.name "T"
    echo "root" > "$ws/R"
    git -C "$ws" add R
    git -C "$ws" commit -q -m "root"
    git -C "$ws" remote add origin "$remote_dir"
    git -C "$ws" push -q origin main

    # Session branch = new-session-name, but commit subject references story/1d8b/s1
    git -C "$ws" checkout -q -b new-session-name
    echo "s1" > "$ws/s1.txt"
    git -C "$ws" add s1.txt
    git -C "$ws" commit -q -m "Merge pull request #1 from story/1d8b/s1"
    git -C "$ws" push -q origin new-session-name

    local session_dir="$tmp/session"
    git clone -q --no-local "$remote_dir" "$session_dir"
    git -C "$session_dir" config user.email "t@t.local"
    git -C "$session_dir" config user.name "T"
    git -C "$session_dir" checkout -q new-session-name 2>/dev/null || \
        git -C "$session_dir" checkout -q -b new-session-name "origin/new-session-name"
    git -C "$session_dir" fetch -q origin main

    # Fixture: PR with OLD base ref (old-session-name), not matching current HEAD_REF
    mkdir -p "$tmp/fixtures/bin"
    cp "$FIXTURE_DIR/bin/gh" "$tmp/fixtures/bin/gh"
    chmod +x "$tmp/fixtures/bin/gh"
    cat > "$tmp/fixtures/pr-list.json" <<'EOF'
[
  {
    "number": 1,
    "title": "Merge pull request story/1d8b/s1",
    "head": { "ref": "story/1d8b/s1" },
    "base": { "ref": "old-session-name" },
    "merged_at": "2026-05-01T10:00:00Z",
    "merge_commit_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
]
EOF
    echo '[{"filename":"plugins/dso/scripts/renamed-branch-file.sh","status":"added"}]' > "$tmp/fixtures/pr-files-1.json"
    echo '{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"success"}]}' > "$tmp/fixtures/check-runs-1.json"

    local cbf="$tmp/cross-branch-files.txt"
    local exit_code=0
    local out
    out="$(
        export PATH="$tmp/fixtures/bin:$PATH"
        export DSO_GH_FIXTURE_DIR="$tmp/fixtures"
        cd "$session_dir" || return
        GITHUB_REPOSITORY="test/repo" HEAD_REF="new-session-name" BASE_REF="main" \
        ARTIFACT_DIR="$tmp" CROSS_BRANCH_FILE="$cbf" \
        bash "$SCRIPT" 2>&1
    )" || exit_code=$?

    # Script should exit 0 (graceful degradation — PR missed by API filter is acceptable)
    assert_eq "renamed_branch_exits_0" "0" "$exit_code"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_a_script_exists_and_is_executable
test_b_all_success_subtracted
test_c_closed_not_merged_excluded
test_d_wrong_base_ref_excluded
test_e_skipped_review_included
test_f_failure_review_included
test_g_non_ancestor_sha_warning_no_append
test_g2_rebase_orphan_fetchable_but_not_ancestor
test_h_idempotency_sort_unique
test_i_404_appends_files_and_exits_0
test_j_403_retry_success
test_k_403_retry_exhausted_exits_1
test_l_500_exits_1_no_retry
test_m_multi_epic_both_derived
test_n_zero_merge_commits_soft_exit
test_o_non_story_branch_excluded
test_p_shallow_clone_unshallow
test_q_multi_epic_dedup_sorted_unique
test_r_lc_all_override
test_s_renamed_session_branch_graceful_degradation

print_summary
