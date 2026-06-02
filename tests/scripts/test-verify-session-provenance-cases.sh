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

# ─── t6: sibling merged PR with distinct merge_commit_sha + passed review → provenanced ─
echo
echo "=== t6: merged sibling PR with distinct merge_commit_sha → provenanced (exit 0) ==="
# F2 hardening: covering PRs must have a passing review check to count as covered.
# Use a multi-endpoint mock that returns PR data for /pulls and review-sub-pr=success for /check-runs.
read -r BASE6 FEAT6 REPO6 < <(_make_fake_repo)
MOCK6=$(mktemp -d "${TMPDIR:-/tmp}/mock-gh-t6.XXXXXX")
cat > "$MOCK6/gh" <<'MOCK_T6_EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"/pulls" ]]; then
        echo '[{"number":300,"state":"closed","merged_at":"2026-05-19T00:00:00Z","head":{"sha":"otherSha"},"merge_commit_sha":"thirdSha"}]'
        exit 0
    fi
    if [[ "$arg" == *"/check-runs" ]]; then
        echo '{"check_runs":[{"name":"review-sub-pr","conclusion":"success"}]}'
        exit 0
    fi
done
echo '[]'
exit 0
MOCK_T6_EOF
chmod +x "$MOCK6/gh"
ARTIFACT6=$(mktemp -d)
PATH="$MOCK6:$PATH" DSO_REPO_PATH="$REPO6" DSO_BASE_SHA="$BASE6" DSO_SESSION_HEAD="$FEAT6" \
    DSO_ARTIFACT_DIR="$ARTIFACT6" DSO_GH_REPO="navapbc/test-repo" PR_NUMBER=253 GH_RETRY_MAX=1 \
    bash "$SCRIPT" > /dev/null 2>&1
rc=$?
_expect "t6 exit code 0 (distinct merged PR covers)" "[[ '$rc' == '0' ]]"
rm -rf "$MOCK6" "$ARTIFACT6" "$REPO6"

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
# PR-R1: under v4 the verifier is unaware of DSO-Story trailers (they were
# self-attested claims, not evidence). Every commit goes through the API
# covering-PR + review-sub-pr check. So this test now asserts the
# inverse-of-original behavior: t8 with a fail-loud gh should now hit gh
# (no trailer shortcut) and surface that as a failure.
FAIL_MOCK=$(mktemp -d)
cat > "$FAIL_MOCK/gh" <<'FAILGH'
#!/usr/bin/env bash
# Under v4 we EXPECT gh to be called for every commit. Return empty so
# the verifier treats the commit as unprovenanced (the negative-path
# assertion below).
echo "[]"
FAILGH
chmod +x "$FAIL_MOCK/gh"
ARTIFACT_DIR=$(mktemp -d)
PATH="$FAIL_MOCK:$PATH" DSO_REPO_PATH="$TRAILER_REPO" DSO_BASE_SHA="$BASE" DSO_SESSION_HEAD="$FEAT" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR" DSO_GH_REPO="navapbc/test-repo" PR_NUMBER="253" GH_RETRY_MAX=1 \
    bash "$SCRIPT" > /dev/null 2>&1
rc=$?
_expect "t8 v4: trailer is no longer load-bearing; commit needs API verification" "[[ '$rc' != '0' ]]"
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
# ─── t11: cache_version mismatch → empty cache (no poisoning across versions) ─
echo
echo "=== t11: cache_version mismatch → cache is reinitialized ==="
ARTIFACT_DIR_T11=$(mktemp -d)
# Seed a v1 (broken/legacy) cache file
echo '{"some-sha": "provenanced"}' > "$ARTIFACT_DIR_T11/session-provenance-cache.json"
read -r BASE FEAT REPO < <(_make_fake_repo)
MOCK_DIR=$(_make_mock_gh "[]")
PATH="$MOCK_DIR:$PATH" DSO_REPO_PATH="$REPO" DSO_BASE_SHA="$BASE" DSO_SESSION_HEAD="$FEAT" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR_T11" DSO_GH_REPO="navapbc/test-repo" PR_NUMBER="253" GH_RETRY_MAX=1 \
    bash "$SCRIPT" > /dev/null 2>&1 || true
# After run, cache file should have version=4 (PR-R1: bumped v3 → v4 with the
# trailer self-attestation removal).
cache_version=$(python3 -c "import json; print(json.load(open('$ARTIFACT_DIR_T11/session-provenance-cache.json')).get('cache_version'))" 2>/dev/null)
_expect "t11 cache reinitialized to v4 on schema mismatch" "[[ '$cache_version' == '4' ]]"
rm -rf "$MOCK_DIR" "$ARTIFACT_DIR_T11" "$REPO"

# ─── t13: cache HIT — pre-populated v2 cache returns verdict without API call ─
echo
echo "=== t13: cache hit on v2 cache skips API call ==="
ARTIFACT_DIR_T13=$(mktemp -d)
read -r BASE FEAT REPO < <(_make_fake_repo)
# Pre-populate cache with the feature SHA + PR_NUMBER=253 → "provenanced".
# Format must match the v4 schema (PR-R1) and the _cache_key derivation: ${sha}.pr${pr}.
cat > "$ARTIFACT_DIR_T13/session-provenance-cache.json" <<EOF
{"cache_version": 4, "entries": {"$FEAT.pr253": "provenanced"}}
EOF
# Mock gh is fail-loud — should never be called because cache hit short-circuits.
FAIL_LOUD_MOCK=$(mktemp -d)
cat > "$FAIL_LOUD_MOCK/gh" <<'FAILLOUD'
#!/usr/bin/env bash
echo "ERROR: gh should not have been called — cache hit expected" >&2
exit 1
FAILLOUD
chmod +x "$FAIL_LOUD_MOCK/gh"
PATH="$FAIL_LOUD_MOCK:$PATH" DSO_REPO_PATH="$REPO" DSO_BASE_SHA="$BASE" DSO_SESSION_HEAD="$FEAT" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR_T13" DSO_GH_REPO="navapbc/test-repo" PR_NUMBER="253" GH_RETRY_MAX=1 \
    bash "$SCRIPT" > /dev/null 2>&1
rc=$?
_expect "t13 cache hit short-circuits API call (exit 0)" "[[ '$rc' == '0' ]]"
rm -rf "$FAIL_LOUD_MOCK" "$ARTIFACT_DIR_T13" "$REPO"

# ─── t12: API error → NOT cached (poisoning prevention) ───────────────────────
echo
echo "=== t12: API error (gh non-zero exit) → SHA flagged but not cached ==="
ARTIFACT_DIR_T12=$(mktemp -d)
# Mock gh that returns non-zero (rate-limit-like persistent failure)
FAIL_MOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fail-gh.XXXXXX")
cat > "$FAIL_MOCK_DIR/gh" <<'FAIL_GH_EOF'
#!/usr/bin/env bash
echo "FAKE: rate limit exceeded" >&2
exit 1
FAIL_GH_EOF
chmod +x "$FAIL_MOCK_DIR/gh"
read -r BASE FEAT REPO < <(_make_fake_repo)
PATH="$FAIL_MOCK_DIR:$PATH" DSO_REPO_PATH="$REPO" DSO_BASE_SHA="$BASE" DSO_SESSION_HEAD="$FEAT" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR_T12" DSO_GH_REPO="navapbc/test-repo" PR_NUMBER="253" GH_RETRY_MAX=1 \
    bash "$SCRIPT" > /dev/null 2>&1 || true
# Cache file should exist (initialized) but the SHA should NOT be in entries
cache_has_sha=$(python3 -c "
import json
data = json.load(open('$ARTIFACT_DIR_T12/session-provenance-cache.json'))
entries = data.get('entries', {})
# Look for any key starting with the feature sha
print('yes' if any(k.startswith('$FEAT') for k in entries) else 'no')
" 2>/dev/null)
_expect "t12 API error does NOT poison cache" "[[ '$cache_has_sha' == 'no' ]]"
rm -rf "$FAIL_MOCK_DIR" "$ARTIFACT_DIR_T12" "$REPO"

# ─── t14 (bug 8a77 v2): `git diff-tree -m` extracts files from merge commit ───
# This test validates the empirical premise behind ci.yml Change C and Change E.
# The OLD form (`git diff-tree --no-commit-id -r --name-only <merge_sha>`)
# returns empty for merge commits — silently dropping the merge SHA's files
# from INTEGRATION_SCOPE. The NEW form (`git diff-tree -m --no-commit-id
# --name-only -r <merge_sha>`) returns the union of file changes across each
# parent, exposing the feature file.
echo
echo "=== t14: git diff-tree -m exposes files from merge commit ==="
T14_REPO=$(mktemp -d "${TMPDIR:-/tmp}/t14-merge.XXXXXX")
T14_MSHA_FILE=$(mktemp "${TMPDIR:-/tmp}/t14-msha.XXXXXX")
(
    cd "$T14_REPO" || exit
    git init -q -b main
    git config user.email t@example.com
    git config user.name Test
    echo base > base.txt
    git add base.txt
    git commit -q -m "base"
    git checkout -q -b feature
    echo feat > feature-file.txt
    git add feature-file.txt
    git commit -q -m "feat commit"
    git checkout -q main
    git merge -q --no-ff --no-edit feature
    MSHA=$(git rev-parse HEAD)
    echo "$MSHA" > "$T14_MSHA_FILE"
)
T14_MSHA=$(cat "$T14_MSHA_FILE")
T14_OLD=$(cd "$T14_REPO" && git diff-tree --no-commit-id -r --name-only "$T14_MSHA" 2>/dev/null || true)
T14_NEW=$(cd "$T14_REPO" && git diff-tree -m --no-commit-id --name-only -r "$T14_MSHA" 2>/dev/null || true)
_expect "t14a: OLD diff-tree returns empty for merge commit (premise)" "[[ -z '$T14_OLD' ]]"
_expect "t14b: NEW diff-tree -m includes feature-file.txt" "[[ '$T14_NEW' == *'feature-file.txt'* ]]"
rm -f "$T14_MSHA_FILE"
rm -rf "$T14_REPO"

# Run the verifier against an explicit (base, head, repo) — like _run_verifier but
# for a caller-built topology (e.g. a staged branch whose HEAD is a merge commit).
_run_verifier_repo() {
    local pr_payload="$1" pr_number_env="$2" base_sha="$3" head_sha="$4" repo_path="$5"
    local mock_dir; mock_dir=$(_make_mock_gh "$pr_payload")
    local artifact_dir; artifact_dir=$(mktemp -d "${TMPDIR:-/tmp}/wcl-artifact.XXXXXX")
    local out_file; out_file=$(mktemp)
    PATH="$mock_dir:$PATH" \
    DSO_REPO_PATH="$repo_path" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$head_sha" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="navapbc/test-repo" \
    PR_NUMBER="$pr_number_env" \
    GH_RETRY_MAX=1 \
        bash "$SCRIPT" > "$out_file" 2>&1
    echo "RC=$?"
    echo "UNPROVENANCED_FILE:"
    if [[ -f "$artifact_dir/unprovenanced-shas.txt" ]]; then cat "$artifact_dir/unprovenanced-shas.txt"; else echo "(absent)"; fi
    rm -rf "$mock_dir" "$artifact_dir"; rm -f "$out_file"; return 0
}

# ─── t15 (bug 77ab): a CLEAN staged merge commit is EXEMPT from provenance ────
# The two-tier staged->main PR's HEAD is the merge commit PR1 created when it
# merged into staged. Its only covering PR (the sub-PR) is dropped by the A3b
# self-merge guard (merge_commit_sha == sha), so without a clean-merge exemption it
# is flagged unprovenanced -> dispatcher fails closed on the empty net diff. A clean
# merge introduces no content of its own; its parents are provenanced independently
# in this same walk. Mirrors review-coverage-invariant.sh::_is_clean_merge.
echo
echo "=== t15: clean staged merge commit is exempt (not unprovenanced) ==="
T15_REPO=$(mktemp -d "${TMPDIR:-/tmp}/t15-merge.XXXXXX")
read -r T15_BASE T15_MERGE T15_FEAT < <(
    cd "$T15_REPO" || exit
    git init -q -b main; git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
    echo base > base.txt; git add base.txt; git commit -q -m base; git rev-parse HEAD | tr '\n' ' '
    git checkout -q -b feature; echo feat > feature.txt; git add feature.txt; git commit -q -m "feature commit"
    git checkout -q main; git checkout -q -b staged
    git merge -q --no-ff -m "Merge pull request #530 from feature" feature
    git rev-parse HEAD | tr '\n' ' '; git rev-parse feature
)
# Merged sub-PR whose merge_commit_sha IS the staged merge commit (the A3b case).
T15_PAYLOAD='[{"number":530,"state":"closed","merged_at":"2026-01-01T00:00:00Z","head":{"sha":"'"$T15_FEAT"'"},"merge_commit_sha":"'"$T15_MERGE"'"}]'
T15_UNPROV=$(_run_verifier_repo "$T15_PAYLOAD" "531" "$T15_BASE" "$T15_MERGE" "$T15_REPO" | sed -n '/UNPROVENANCED_FILE:/,$p')
if grep -q "$T15_MERGE" <<< "$T15_UNPROV"; then T15_RES=flagged; else T15_RES=exempt; fi
_expect "t15: clean merge commit is exempt (not flagged unprovenanced)" "[[ '$T15_RES' == 'exempt' ]]"
# Anti-laundering: the exemption covers ONLY the merge; an unreviewed parent is still flagged.
if grep -q "$T15_FEAT" <<< "$T15_UNPROV"; then T15B_RES=flagged; else T15B_RES=exempt; fi
_expect "t15b: clean merge does NOT launder its unreviewed feature parent" "[[ '$T15B_RES' == 'flagged' ]]"
rm -rf "$T15_REPO"

# ─── t16 (bug 77ab): an EVIL merge (own content) is NOT exempt ────────────────
echo
echo "=== t16: evil merge (manual edits -> non-empty combined diff) still requires provenance ==="
T16_REPO=$(mktemp -d "${TMPDIR:-/tmp}/t16-merge.XXXXXX")
read -r T16_BASE T16_EVIL < <(
    cd "$T16_REPO" || exit
    git init -q -b main; git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
    echo base > base.txt; git add base.txt; git commit -q -m base; git rev-parse HEAD | tr '\n' ' '
    git checkout -q -b feature; echo feat > feature.txt; git add feature.txt; git commit -q -m "feature commit"
    git checkout -q main; git checkout -q -b staged
    git merge -q --no-ff --no-commit feature >/dev/null 2>&1 || true
    echo evil-injected > base.txt; git add base.txt; git commit -q -m "Merge pull request #531 (evil)"
    git rev-parse HEAD
)
T16_UNPROV=$(_run_verifier_repo '[]' "531" "$T16_BASE" "$T16_EVIL" "$T16_REPO" | sed -n '/UNPROVENANCED_FILE:/,$p')
if grep -q "$T16_EVIL" <<< "$T16_UNPROV"; then T16_RES=flagged; else T16_RES=exempt; fi
_expect "t16: evil merge is NOT exempt (still flagged unprovenanced)" "[[ '$T16_RES' == 'flagged' ]]"
rm -rf "$T16_REPO"

echo "================================="
echo "Results: $PASS passed, $FAIL failed"
echo "================================="
[[ $FAIL -eq 0 ]]
