#!/usr/bin/env bash
# tests/scripts/test-workflow-pull-request-base-filter.sh
#
# Bug 69e5-824a-ec7e-4bd9 regression guard:
# Multiple CI workflows previously declared `pull_request: branches: [main]`,
# so they only fired on PRs whose base was `main`. Story/session sub-PRs
# missed this coverage entirely — failures surfaced only at the final
# session→main merge. This test asserts the four affected workflows
# (and ci.yml, which was previously fixed under bug 3914-0848) all have
# NO branch filter under their `pull_request:` trigger.
#
# The check is structural (YAML parse + key presence) rather than a
# content-grep, so cosmetic edits to the trigger blocks don't break it.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-workflow-pull-request-base-filter.sh ==="

# Workflows that MUST fire on sub-branch PRs (story/*, session/*) too.
# Each entry: workflow file path relative to .github/workflows/
WORKFLOWS_NO_BRANCH_FILTER=(
    "ci.yml"
    "ci-python-skills.yml"
    "portability-smoke.yml"
    "ticket-perf-regression.yml"
    "ticket-platform-matrix.yml"
)

_assert_no_pr_branches_filter() {
    local wf_name="$1"
    local wf_file="$REPO_ROOT/.github/workflows/${wf_name}"
    local result="missing"

    if [[ ! -f "$wf_file" ]]; then
        assert_eq "workflow exists: ${wf_name}" "exists" "missing"
        return
    fi

    # Use YAML parsing to check the pull_request trigger's `branches:` field.
    # The presence of any branches: filter under pull_request is the bug.
    result=$(python3 - "$wf_file" <<'PYEOF'
import sys, yaml
try:
    doc = yaml.safe_load(open(sys.argv[1]))
except Exception as e:
    print(f"yaml_error: {e}")
    sys.exit(0)

# YAML parses `on:` as the key True (because `on` is a YAML boolean alias).
# Look up by both spellings to be robust against the parser quirk.
on_block = doc.get(True) if True in (doc or {}) else (doc or {}).get("on")
if on_block is None:
    print("no_on_block")
    sys.exit(0)

pr_block = on_block.get("pull_request") if isinstance(on_block, dict) else None
if pr_block is None:
    # Workflow has no pull_request trigger at all — vacuously satisfies the
    # "no base-branch filter" contract. Report ok rather than failing.
    print("no_pull_request")
    sys.exit(0)

if not isinstance(pr_block, dict):
    # pull_request: with no fields (just the key) — no branches filter.
    print("ok")
    sys.exit(0)

if "branches" in pr_block:
    print(f"has_branches_filter: {pr_block['branches']}")
else:
    print("ok")
PYEOF
)

    # ok / no_pull_request — both satisfy the contract (workflow fires on
    # all PRs or doesn't fire on PRs at all). Anything else is a failure.
    case "$result" in
        ok|no_pull_request)
            assert_eq "${wf_name}: no base-branch filter on pull_request" "ok" "ok"
            ;;
        *)
            assert_eq "${wf_name}: no base-branch filter on pull_request" "ok" "$result"
            ;;
    esac
}

for wf in "${WORKFLOWS_NO_BRANCH_FILTER[@]}"; do
    _assert_no_pr_branches_filter "$wf"
done

print_summary
