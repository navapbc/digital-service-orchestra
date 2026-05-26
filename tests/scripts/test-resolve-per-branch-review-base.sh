#!/usr/bin/env bash
# tests/scripts/test-resolve-per-branch-review-base.sh
# Behavioral tests for plugins/dso/scripts/resolve-per-branch-review-base.sh.
#
# Bug 3914-0848-faad-4f6a: SPRINT_SESSION_ID coupling -> stale variable
# produces wrong-scoped reviews when PR base is available.
#
# These tests exercise the script's OBSERVABLE behavior (its stdout output
# given a set of env-var inputs and stubbed external commands). They do NOT
# grep the source file — per the behavioral testing standard, content
# matching would survive a rewrite that preserved behavior.
#
# Coverage:
#   1. Open PR exists → BASE_REF = PR's baseRefName (Stage 1)
#   2. No PR + SPRINT_SESSION_ID set → BASE_REF = SPRINT_SESSION_ID (Stage 2)
#   3. No PR + no SPRINT_SESSION_ID → BASE_REF = main (Stage 3)
#   4. PR base wins over SPRINT_SESSION_ID when both available (Stage 1 priority)
#   5. Resolved base missing on origin → downgrades to main
#
# Usage: bash tests/scripts/test-resolve-per-branch-review-base.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/resolve-per-branch-review-base.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-resolve-per-branch-review-base.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d /tmp/test-resolve-per-branch.XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Helper: build a stub `gh` and `git ls-remote` binary set that returns
# the supplied JSON for `gh pr list --head ... --json baseRefName`, and
# claims the supplied base ref exists on origin (when EXISTS=1).
# Usage: _make_stub_bin <gh_pr_list_jq_output> <existing_base_ref_or_empty>
_make_stub_bin() {
    local jq_output="$1"       # what `gh pr list --jq ...` should return
    local existing_ref="$2"    # branch that `git ls-remote --heads` should claim exists
    local bin
    bin="$(mktemp -d "$TMPDIR_TEST/stub-XXXXXX")"

    # Stub gh: returns jq_output for `pr list --head ... --json baseRefName --jq ...`
    cat > "$bin/gh" << GHSTUB
#!/usr/bin/env bash
# Only handle the specific call we expect; ignore others.
case "\$*" in
    *pr\ list*--head*--json*baseRefName*)
        printf '%s' "$jq_output"
        exit 0
        ;;
    *)
        # Unknown gh call; emit nothing, exit 0 so the script falls through.
        exit 0
        ;;
esac
GHSTUB
    chmod +x "$bin/gh"

    # Stub git: pass through to real git EXCEPT for ls-remote --heads origin <ref>
    # which we control to simulate "branch exists / doesn't exist".
    cat > "$bin/git" << GITSTUB
#!/usr/bin/env bash
# Intercept the existence check; pass everything else through to real git.
if [[ "\$1" == "ls-remote" && "\$*" == *"--heads"*"origin"* ]]; then
    # Last argument is the ref being checked.
    _ref="\${!#}"
    if [[ "\$_ref" == "$existing_ref" ]]; then
        echo "deadbeef\trefs/heads/\$_ref"
        exit 0
    else
        exit 2  # not found
    fi
fi
exec /usr/bin/env -i PATH=/usr/bin:/bin git "\$@"
GITSTUB
    chmod +x "$bin/git"

    echo "$bin"
}

# ── Test 1: open PR → BASE_REF is the PR's baseRefName (Stage 1) ─────────────
test_pr_base_when_open_pr_exists() {
    local stub_bin out
    stub_bin="$(_make_stub_bin "story/d076/2abb-actual-pr-base" "story/d076/2abb-actual-pr-base")"
    out="$(BRANCH_NAME="my-feature-branch" \
        SPRINT_SESSION_ID="some-stale-session-id" \
        PATH="$stub_bin:$PATH" \
        bash "$SCRIPT" 2>/dev/null)"
    assert_eq "test_pr_base_when_open_pr_exists: BASE_REF resolves to PR's baseRefName even when SPRINT_SESSION_ID is set" \
        "story/d076/2abb-actual-pr-base" "$out"
}

# ── Test 2: no PR + SPRINT_SESSION_ID set → BASE_REF = SPRINT_SESSION_ID ─────
test_falls_back_to_sprint_session_id_when_no_pr() {
    local stub_bin out
    # gh returns empty → no open PR found
    stub_bin="$(_make_stub_bin "" "session-x")"
    out="$(BRANCH_NAME="my-feature-branch" \
        SPRINT_SESSION_ID="session-x" \
        PATH="$stub_bin:$PATH" \
        bash "$SCRIPT" 2>/dev/null)"
    assert_eq "test_falls_back_to_sprint_session_id: BASE_REF = SPRINT_SESSION_ID when no PR + variable set + exists on origin" \
        "session-x" "$out"
}

# ── Test 3: no PR + no variable → BASE_REF = main ────────────────────────────
test_falls_back_to_main_when_neither() {
    local stub_bin out
    stub_bin="$(_make_stub_bin "" "main")"
    out="$(BRANCH_NAME="my-feature-branch" \
        SPRINT_SESSION_ID="" \
        PATH="$stub_bin:$PATH" \
        bash "$SCRIPT" 2>/dev/null)"
    assert_eq "test_falls_back_to_main: BASE_REF = main when no PR and no SPRINT_SESSION_ID" \
        "main" "$out"
}

# ── Test 4: PR base WINS over SPRINT_SESSION_ID (Stage 1 priority) ──────────
# This is the structural intent of the fix: even if a stale SPRINT_SESSION_ID
# remains set, the open PR's baseRefName must take precedence.
test_pr_base_priority_over_sprint_session_id() {
    local stub_bin out
    stub_bin="$(_make_stub_bin "the-correct-pr-base" "the-correct-pr-base")"
    out="$(BRANCH_NAME="my-feature-branch" \
        SPRINT_SESSION_ID="stale-worktree-name-from-prior-sprint" \
        PATH="$stub_bin:$PATH" \
        bash "$SCRIPT" 2>/dev/null)"
    assert_eq "test_pr_base_priority: PR's baseRefName WINS even when stale SPRINT_SESSION_ID is set" \
        "the-correct-pr-base" "$out"
}

# ── Test 5: missing-on-origin → downgrade to main ────────────────────────────
test_downgrades_to_main_when_base_missing_on_origin() {
    local stub_bin out
    # gh returns empty; SPRINT_SESSION_ID set to a ref that does NOT exist on origin
    stub_bin="$(_make_stub_bin "" "main")"   # only "main" claimed to exist
    out="$(BRANCH_NAME="my-feature-branch" \
        SPRINT_SESSION_ID="this-branch-does-not-exist" \
        PATH="$stub_bin:$PATH" \
        bash "$SCRIPT" 2>/dev/null)"
    assert_eq "test_downgrades_to_main_when_base_missing: BASE_REF downgrades to main when resolved ref is missing on origin" \
        "main" "$out"
}

# ── Run all tests ───────────────────────────────────────────────────────────
test_pr_base_when_open_pr_exists
test_falls_back_to_sprint_session_id_when_no_pr
test_falls_back_to_main_when_neither
test_pr_base_priority_over_sprint_session_id
test_downgrades_to_main_when_base_missing_on_origin

print_summary
