#!/usr/bin/env bash
# tests/scripts/test-per-branch-review-trigger-parity.sh
# Trigger-parity regression: per-branch-review.yml's push.branches MUST cover
# every sub-branch pattern produced by orchestrators that rely on this workflow
# for LLM Story/Sub-Branch Review.
#
# Background (Flow C gap): d076's spec said `story/**, fix/**, bug-batch/**`.
# Implementation shipped `story/**` only. Result: every debug-everything
# bug-batch/** PR merged to its session branch without ever firing CI review,
# and the silent-skip propagated to main when the session→main PR merged with
# only ci.yml's llm-review job — which itself was kill-switched on direct PRs
# until PR #188 restored the full-PR-diff fallback.
#
# This test pins the workflow's push.branches to the documented contract so
# future drift (e.g., re-narrowing the triggers, dropping a pattern) is caught
# at CI time rather than discovered after months of unreviewed merges.
#
# Usage: bash tests/scripts/test-per-branch-review-trigger-parity.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Canonical: git rev-parse --show-toplevel handles symlinks, submodules, and
# nested working directories correctly. The tests always run inside a git
# checkout; no fallback path is meaningful when git is unavailable.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/per-branch-review.yml"

# shellcheck source=tests/lib/run_test.sh
source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-per-branch-review-trigger-parity.sh ==="

# Helper: extract the `on.push.branches:` list from per-branch-review.yml as a
# newline-separated list of bare pattern values (no leading dash, no quotes).
# Handles BOTH YAML forms:
#   block:   `branches:` followed by `- pattern` lines
#   inline:  `branches: [pattern, pattern, ...]`
# (Inline form is used elsewhere in this repo — e.g.
# `.github/workflows/ticket-perf-regression.yml` — so the extractor must not
# format-couple to the block form alone.)
_extract_push_branches() {
    awk '
        /^on:/                          { in_on=1; next }
        in_on && /^[^[:space:]]/        { in_on=0 }
        in_on && /^[[:space:]]+push:/   { in_push=1; next }
        in_push && /^[[:space:]]{2}[^[:space:]]/ { in_push=0 }
        in_push && /branches:/ {
            line = $0
            if (line ~ /branches:[[:space:]]*\[/) {
                # Inline form: branches: [a, b, c]
                sub(/.*\[/, "", line)
                sub(/\].*/, "", line)
                n = split(line, arr, ",")
                for (i = 1; i <= n; i++) {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", arr[i])
                    gsub(/^['\''"]|['\''"]$/, "", arr[i])
                    if (arr[i] != "") print "- " arr[i]
                }
            } else {
                in_branches=1
            }
            next
        }
        # Block form: skip blanks/comments inside branches without leaving the block
        in_branches && /^[[:space:]]*$/ { next }
        in_branches && /^[[:space:]]+#/ { next }
        in_branches && /^[[:space:]]+- / { print; next }
        in_branches && !/^[[:space:]]+- / { in_branches=0 }
    ' "$WORKFLOW_FILE" | sed -E "s/^[[:space:]]+- //; s/^- //; s/^['\"]//; s/['\"]$//"
}

# Test 1: Workflow file exists
echo "Test 1: per-branch-review.yml exists"
if [[ -f "$WORKFLOW_FILE" ]]; then
    echo "  PASS: workflow file found"
    PASS=$((PASS+1))
else
    echo "  FAIL: workflow file not found at $WORKFLOW_FILE" >&2
    FAIL=$((FAIL+1))
    print_results
fi

# Test 2: push.branches contains story/** (existing contract)
echo "Test 2: push.branches contains story/**"
if _extract_push_branches | grep -qFx "story/**"; then
    echo "  PASS: story/** present"
    PASS=$((PASS+1))
else
    echo "  FAIL: push.branches missing story/**" >&2
    echo "  push.branches values were:" >&2
    _extract_push_branches | sed 's/^/    /' >&2
    FAIL=$((FAIL+1))
fi

# Test 3: push.branches contains bug-batch/** (Flow C — debug-everything)
# debug-everything/SKILL.md Phase F line 730-731 and Phase G line 791 create
# bug-batch/<session>/tier-N[-batch-K] sub-branches and rely on this workflow
# firing on push. Without bug-batch/** in the trigger filter, every Phase F/G
# sub-branch PR merges to the session branch unreviewed.
echo "Test 3: push.branches contains bug-batch/**"
if _extract_push_branches | grep -qFx "bug-batch/**"; then
    echo "  PASS: bug-batch/** present"
    PASS=$((PASS+1))
else
    echo "  FAIL: push.branches missing bug-batch/** (Flow C gap — debug-everything sub-branches will not fire CI review)" >&2
    echo "  push.branches values were:" >&2
    _extract_push_branches | sed 's/^/    /' >&2
    FAIL=$((FAIL+1))
fi

# Test 4: push.branches contains fix/** (d076 spec coverage)
# d076 epic's original spec named story/**, fix/**, bug-batch/** as the three
# sub-branch namespaces. The fix/** pattern is reserved for ad-hoc fix branches
# that should also fire per-branch review when pushed.
echo "Test 4: push.branches contains fix/**"
if _extract_push_branches | grep -qFx "fix/**"; then
    echo "  PASS: fix/** present"
    PASS=$((PASS+1))
else
    echo "  FAIL: push.branches missing fix/** (d076 spec coverage gap)" >&2
    echo "  push.branches values were:" >&2
    _extract_push_branches | sed 's/^/    /' >&2
    FAIL=$((FAIL+1))
fi

# Test 5: SKILL.md prose claims match workflow reality (debug-everything)
# Catches future drift where someone removes a pattern from the workflow but
# leaves the prose claim in debug-everything's SKILL.md untouched.
echo "Test 5: debug-everything SKILL.md prose claim matches workflow trigger"
DEBUG_SKILL="$REPO_ROOT/plugins/dso/skills/debug-everything/SKILL.md"
if [[ -f "$DEBUG_SKILL" ]] && grep -qE 'per-branch-review\.yml' "$DEBUG_SKILL"; then
    # SKILL.md claims per-branch-review.yml fires for bug-batch sub-branches.
    # That claim is only true if bug-batch/** is in the workflow trigger.
    if _extract_push_branches | grep -qFx "bug-batch/**"; then
        echo "  PASS: SKILL.md references per-branch-review.yml AND workflow covers bug-batch/**"
        PASS=$((PASS+1))
    else
        echo "  FAIL: debug-everything/SKILL.md claims per-branch-review.yml fires for sub-branches but bug-batch/** is not in the workflow trigger" >&2
        FAIL=$((FAIL+1))
    fi
else
    # Test is conditional: only meaningful if SKILL.md still makes the claim.
    echo "  PASS: debug-everything SKILL.md no longer references per-branch-review.yml (no parity claim to enforce)"
    PASS=$((PASS+1))
fi

print_results
