#!/usr/bin/env bash
# RED tests for bug 8a77-eda4-e03d-4371: verify-session-provenance.sh
# treats the PR-under-review as its own "covering sub-PR" → every PR's
# llm-review is skipped with CONCLUSION:skipped → arbiter never dispatches.
#
# Fix scope: layered API filters
#   A4 (trailer-first; already in place at line 138-152 of the script)
#   A2 (filter API result by state="closed" AND merged_at != null)
#   A3a (filter by head.sha != $sha — PR cannot cover its own HEAD)
#   A3b (filter by merge_commit_sha != $sha — self-merge guard)
#   A1 (filter by number != $PR_NUMBER — self-exclusion via env var)
#
# Test pattern: PATH-prepended mock `gh` binary returns canned JSON per case;
# fake git repo provides BASE..HEAD with one synthetic commit; assertions on
# exit code + unprovenanced-shas.txt content.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"

PASS=0
FAIL=0

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Create a fake git repo with two commits (BASE + one feature commit) and
# return the (BASE_SHA, FEATURE_SHA, REPO_PATH) via stdout.
_make_fake_repo() {
    local repo
    repo=$(mktemp -d "${TMPDIR:-/tmp}/fake-repo.XXXXXX")
    (
        cd "$repo" || exit
        git init -q -b main
        git config user.email t@example.com
        git config user.name Test
        echo base > base.txt
        git add base.txt
        git commit -q -m "base commit"
        local base
        base=$(git rev-parse HEAD)
        echo feature > feature.txt
        git add feature.txt
        # Note: no DSO-Story-Merge trailer — this commit should go through
        # the API path, not the trailer-first path.
        git commit -q -m "feature commit (untrailered)"
        local feature
        feature=$(git rev-parse HEAD)
        echo "$base $feature $repo"
    )
}

# Create a mock gh binary that emits a fixed response for `gh api ...` and
# exits 0. Pass the response payload via $1.
_make_mock_gh() {
    local payload="$1"
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/mock-gh.XXXXXX")
    cat > "$dir/gh" <<MOCK_GH_EOF
#!/usr/bin/env bash
# Minimal mock — every \`gh api\` call returns the canned payload.
case "\$1" in
    api)
        cat <<'GH_PAYLOAD_EOF'
$payload
GH_PAYLOAD_EOF
        exit 0
        ;;
    *)
        echo "{}"
        exit 0
        ;;
esac
MOCK_GH_EOF
    chmod +x "$dir/gh"
    echo "$dir"
}

# Run the verifier against a fake repo + mock gh; capture exit code + stdout.
# Usage: _run <pr_payload> <pr_number_env> [<extra_env>]
_run_verifier() {
    local pr_payload="$1"
    local pr_number_env="${2:-}"
    local feature_sha base_sha repo_path
    read -r base_sha feature_sha repo_path < <(_make_fake_repo)
    local mock_dir
    mock_dir=$(_make_mock_gh "$pr_payload")
    local artifact_dir
    artifact_dir=$(mktemp -d "${TMPDIR:-/tmp}/wcl-artifact.XXXXXX")
    local out_file
    out_file=$(mktemp)
    PATH="$mock_dir:$PATH" \
    DSO_REPO_PATH="$repo_path" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$feature_sha" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="navapbc/test-repo" \
    PR_NUMBER="$pr_number_env" \
    GH_RETRY_MAX=1 \
        bash "$SCRIPT" > "$out_file" 2>&1
    local rc=$?
    # Print: rc, stdout/stderr content, unprovenanced file existence
    echo "RC=$rc"
    echo "OUTPUT:"
    cat "$out_file"
    echo "UNPROVENANCED_FILE:"
    if [[ -f "$artifact_dir/unprovenanced-shas.txt" ]]; then
        cat "$artifact_dir/unprovenanced-shas.txt"
    else
        echo "(absent)"
    fi
    echo "FEATURE_SHA=$feature_sha"
    rm -rf "$mock_dir" "$artifact_dir" "$repo_path"
    rm -f "$out_file"
    return 0
}

# Assertion helper.
_expect() {
    local label="$1"
    local cond="$2"
    if eval "$cond"; then
        echo "PASS: $label"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL: $label"
        echo "  cond: $cond"
        FAIL=$(( FAIL + 1 ))
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test cases
# ─────────────────────────────────────────────────────────────────────────────

# ─── t1: empty PR list → unprovenanced (exit 1) ───────────────────────────────
echo
echo "=== t1: empty PR list → unprovenanced ==="
output=$(_run_verifier "[]" "")
rc=$(echo "$output" | grep -oE 'RC=[0-9]+' | head -1 | cut -d= -f2)
_expect "t1 exit code 1 (unprovenanced)" "[[ '$rc' == '1' ]]"

# ─── t2: only self-PR (number=253) covers commit → unprovenanced (A1) ─────────
echo
echo "=== t2: only self-PR covers commit → unprovenanced (A1) ==="
output=$(_run_verifier '[{"number":253,"state":"closed","merged_at":"2026-05-20T00:00:00Z","head":{"sha":"deadbeef"},"merge_commit_sha":"otherSha"}]' "253")
rc=$(echo "$output" | grep -oE 'RC=[0-9]+' | head -1 | cut -d= -f2)
_expect "t2 exit code 1 (only self-PR doesn't count as covering)" "[[ '$rc' == '1' ]]"

# ─── t3: sibling draft PR with head.sha == feature_sha → unprovenanced (A2+A3a) ─
echo
echo "=== t3: sibling draft PR (state=open, merged_at=null, head.sha==feature) → unprovenanced ==="
# We don't know feature_sha at test setup time; use a placeholder. The script
# checks merged_at != null AND state == "closed", so an open PR fails A2.
output=$(_run_verifier '[{"number":300,"state":"open","merged_at":null,"head":{"sha":"someSha"},"merge_commit_sha":null}]' "253")
rc=$(echo "$output" | grep -oE 'RC=[0-9]+' | head -1 | cut -d= -f2)
_expect "t3 exit code 1 (open PR doesn't cover)" "[[ '$rc' == '1' ]]"

# ─── t4: sibling unmerged closed PR → unprovenanced (A2 merged_at filter) ─────
echo
echo "=== t4: sibling unmerged closed PR (state=closed, merged_at=null) → unprovenanced ==="
output=$(_run_verifier '[{"number":300,"state":"closed","merged_at":null,"head":{"sha":"someSha"},"merge_commit_sha":null}]' "253")
rc=$(echo "$output" | grep -oE 'RC=[0-9]+' | head -1 | cut -d= -f2)
_expect "t4 exit code 1 (closed-unmerged doesn't cover)" "[[ '$rc' == '1' ]]"

# ─── t5: sibling merged PR whose merge_commit_sha == feature_sha → unprovenanced (A3b) ─
echo
echo "=== t5: merged PR with merge_commit_sha == feature_sha → unprovenanced (A3b) ==="
# The feature_sha is generated per-test; we can't pre-set it. Instead,
# assert that a merged PR whose merge_commit_sha matches the canned
# value is treated as self-merge IF the script's logic is honest.
# This test is approximate; t6 (positive case) is the definitive proof.
# Use a feature_sha matching the expected merge_commit_sha.
read -r BASE FEAT REPO < <(_make_fake_repo)
MOCK_DIR=$(_make_mock_gh "[{\"number\":300,\"state\":\"closed\",\"merged_at\":\"2026-05-19T00:00:00Z\",\"head\":{\"sha\":\"otherSha\"},\"merge_commit_sha\":\"$FEAT\"}]")
ARTIFACT_DIR=$(mktemp -d)
PATH="$MOCK_DIR:$PATH" DSO_REPO_PATH="$REPO" DSO_BASE_SHA="$BASE" DSO_SESSION_HEAD="$FEAT" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR" DSO_GH_REPO="navapbc/test-repo" PR_NUMBER="253" GH_RETRY_MAX=1 \
    bash "$SCRIPT" > /dev/null 2>&1
rc=$?
_expect "t5 exit code 1 (merge_commit_sha==feature → not covering)" "[[ '$rc' == '1' ]]"
rm -rf "$MOCK_DIR" "$ARTIFACT_DIR" "$REPO"

# ─── t6: sibling merged PR with distinct merge_commit_sha → provenanced (positive) ─
echo
echo "=== t6: merged sibling PR with distinct merge_commit_sha → provenanced (exit 0) ==="
output=$(_run_verifier '[{"number":300,"state":"closed","merged_at":"2026-05-19T00:00:00Z","head":{"sha":"otherSha"},"merge_commit_sha":"thirdSha"}]' "253")
rc=$(echo "$output" | grep -oE 'RC=[0-9]+' | head -1 | cut -d= -f2)
_expect "t6 exit code 0 (distinct merged PR covers)" "[[ '$rc' == '0' ]]"

# ─── t7: PR_NUMBER unset + head.sha == feature_sha self-match → unprovenanced (push-event case) ─
echo
echo "=== t7: PR_NUMBER unset + head.sha self-match → unprovenanced (push-event A3a) ==="
read -r BASE FEAT REPO < <(_make_fake_repo)
# Only self-cover: PR 253 with head.sha == feature commit. Without PR_NUMBER,
# A1 self-exclusion does nothing; A3a (head.sha != $sha) must catch this.
MOCK_DIR=$(_make_mock_gh "[{\"number\":253,\"state\":\"closed\",\"merged_at\":\"2026-05-20T00:00:00Z\",\"head\":{\"sha\":\"$FEAT\"},\"merge_commit_sha\":\"otherSha\"}]")
ARTIFACT_DIR=$(mktemp -d)
PATH="$MOCK_DIR:$PATH" DSO_REPO_PATH="$REPO" DSO_BASE_SHA="$BASE" DSO_SESSION_HEAD="$FEAT" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR" DSO_GH_REPO="navapbc/test-repo" GH_RETRY_MAX=1 \
    bash "$SCRIPT" > /dev/null 2>&1
rc=$?
_expect "t7 exit code 1 (head.sha self-match without PR_NUMBER)" "[[ '$rc' == '1' ]]"
rm -rf "$MOCK_DIR" "$ARTIFACT_DIR" "$REPO"

# ─── t8: trailer-first (DSO-Story-Merge) → provenanced (zero API calls) ───────
echo
echo "=== t8: DSO-Story-Merge trailer → provenanced (A4) ==="
# Build a repo where the feature commit has a DSO-Story-Merge trailer.
TRAILER_REPO=$(mktemp -d "${TMPDIR:-/tmp}/trailer-repo.XXXXXX")
# Per CLAUDE.md `always:mktemp-tmp` rule, the SHA-handoff file must use mktemp
# rather than a hardcoded path; otherwise parallel test invocations race.
TRAILER_SHAS_FILE=$(mktemp "${TMPDIR:-/tmp}/trailer-shas.XXXXXX")
(
    cd "$TRAILER_REPO" || exit
    git init -q -b main
    git config user.email t@example.com
    git config user.name Test
    echo base > base.txt
    git add base.txt
    git commit -q -m "base commit"
    BASE=$(git rev-parse HEAD)
    echo feature > feature.txt
    git add feature.txt
    git commit -q -m "feature commit
DSO-Story-Merge: story/abc/def"
    FEAT=$(git rev-parse HEAD)
    echo "$BASE $FEAT" > "$TRAILER_SHAS_FILE"
) > /dev/null
read -r BASE FEAT < "$TRAILER_SHAS_FILE"
rm -f "$TRAILER_SHAS_FILE"
# Mock gh would fail loudly if called; we expect zero calls. Use a fail-loud mock.
FAIL_MOCK=$(mktemp -d)
cat > "$FAIL_MOCK/gh" <<'FAILGH'
#!/usr/bin/env bash
echo "ERROR: gh should not have been called when trailer is present" >&2
exit 1
FAILGH
chmod +x "$FAIL_MOCK/gh"
ARTIFACT_DIR=$(mktemp -d)
PATH="$FAIL_MOCK:$PATH" DSO_REPO_PATH="$TRAILER_REPO" DSO_BASE_SHA="$BASE" DSO_SESSION_HEAD="$FEAT" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR" DSO_GH_REPO="navapbc/test-repo" PR_NUMBER="253" GH_RETRY_MAX=1 \
    bash "$SCRIPT" > /dev/null 2>&1
rc=$?
_expect "t8 exit code 0 (trailer-only provenance, no API call)" "[[ '$rc' == '0' ]]"
rm -rf "$FAIL_MOCK" "$ARTIFACT_DIR" "$TRAILER_REPO"

# ─── t9: gh api returns rate-limit object → unprovenanced, not poisoned ──────
echo
echo "=== t9: rate-limit object response → unknown-due-to-error (not poisoned) ==="
# A non-array response (object with "message"); pr_count parser returns 0 →
# treats as unprovenanced. We accept either "treat as unprovenanced" or
# "treat as unknown-due-to-error" as long as it doesn't poison the cache.
output=$(_run_verifier '{"message":"API rate limit exceeded","documentation_url":"..."}' "253")
rc=$(echo "$output" | grep -oE 'RC=[0-9]+' | head -1 | cut -d= -f2)
_expect "t9 exit code 1 or 2 (rate-limit treated as unprovenanced / unknown)" "[[ '$rc' == '1' || '$rc' == '2' ]]"

# ─── t10: gh api returns 404 object → unprovenanced ────────────────────────
echo
echo "=== t10: 404 object response → unprovenanced ==="
output=$(_run_verifier '{"message":"Not Found","documentation_url":"..."}' "253")
rc=$(echo "$output" | grep -oE 'RC=[0-9]+' | head -1 | cut -d= -f2)
_expect "t10 exit code 1 (404 treated as unprovenanced)" "[[ '$rc' == '1' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "================================="
echo "Results: $PASS passed, $FAIL failed"
echo "================================="
[[ $FAIL -eq 0 ]]
