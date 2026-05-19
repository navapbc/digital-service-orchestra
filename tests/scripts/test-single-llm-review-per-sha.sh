#!/usr/bin/env bash
# tests/scripts/test-single-llm-review-per-sha.sh
#
# Behavioral test for Story 20d7-09d6-b831-4c3a:
#   "As a CI orchestrator, ci.yml is the sole PR-side LLM-review entry point —
#    per-branch-review.yml is removed so each PR runs exactly one review
#    pipeline per SHA."
#
# Given:  a recorded fixture of `gh api repos/.../actions/runs?head_sha=<sha>`
#         from PR #214 (post-rebase commit 0a3d551bf2...) — this SHA exhibits
#         the duplicate-review bug (both ci.yml AND per-branch-review.yml ran).
# When:   the test counts workflow runs whose `path` is a known LLM-review
#         entry-point workflow for that SHA.
# Then:   exactly 1 LLM-review-class workflow must appear.
#
# RED:    Pre-Task-B state — both .github/workflows/ci.yml and
#         .github/workflows/per-branch-review.yml are present, so the fixture
#         shows 2 LLM-review-class runs. Test FAILS with count=2.
# GREEN:  After Task B deletes per-branch-review.yml, only ci.yml remains as
#         the LLM-review entry point. The test counts paths against the set
#         of currently-existing LLM-review entry points; after deletion the
#         set contains only ci.yml, so the fixture-restricted count is 1.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${REPO_ROOT}/tests/lib/assert.sh"

FIXTURE="${REPO_ROOT}/tests/fixtures/workflow-runs/pr-214-cycle-1.json"

test_fixture_present() {
  if [ -f "${FIXTURE}" ]; then
    assert_eq "test_fixture_present: fixture file exists" "OK" "OK"
  else
    assert_eq "test_fixture_present: fixture file exists" "OK" "MISSING: ${FIXTURE}"
  fi
}

# The set of workflow paths that constitute "LLM-review-class" entry points
# is derived from the *current* state of .github/workflows/ — i.e., which
# workflow files presently invoke the LLM review runner. Pre-deletion this
# set is {ci.yml, per-branch-review.yml}; post-deletion it is {ci.yml}.
#
# We compute the set dynamically by grepping for the ci-llm-review-runner.sh
# invocation across .github/workflows/. This makes the test sensitive to the
# behavioral change (deletion of per-branch-review.yml) without hardcoding
# either file path.
collect_llm_review_workflow_paths() {
  local wf_dir="${REPO_ROOT}/.github/workflows"
  if [ ! -d "${wf_dir}" ]; then
    return 0
  fi
  # List relative paths of workflows that invoke the LLM review runner.
  grep -l "ci-llm-review-runner.sh\|^  llm-review:\|^  llm_review:" \
    "${wf_dir}"/*.yml 2>/dev/null | while read -r f; do
    echo ".github/workflows/$(basename "${f}")"
  done | sort -u
}

test_single_llm_review_per_sha() {
  if [ ! -f "${FIXTURE}" ]; then
    assert_eq "test_single_llm_review_per_sha: fixture present" "OK" "MISSING"
    return
  fi

  # Compute the current set of LLM-review entry-point workflow paths.
  local entry_points
  entry_points="$(collect_llm_review_workflow_paths)"

  if [ -z "${entry_points}" ]; then
    assert_eq "test_single_llm_review_per_sha: at least one LLM-review entry point exists" \
      "non-empty" "EMPTY (no workflows reference ci-llm-review-runner.sh)"
    return
  fi

  # Parse the fixture and count workflow runs whose .path is in entry_points.
  # We use python3 because jq is not guaranteed in DSO test env.
  local count
  count="$(python3 - "${FIXTURE}" <<PY
import json, sys
entry_points = set("""${entry_points}""".strip().splitlines())
with open(sys.argv[1]) as f:
    data = json.load(f)
runs = data.get("workflow_runs", [])
matching = [r for r in runs if r.get("path") in entry_points]
print(len(matching))
PY
)"

  # Behavioral assertion: exactly one LLM-review-class workflow ran for the SHA.
  # RED state: count == 2 (both ci.yml and per-branch-review.yml present
  # AND both ran on the fixture's SHA). FAIL message includes the count.
  if [ "${count}" = "1" ]; then
    assert_eq "test_single_llm_review_per_sha: exactly one llm-review-class workflow per SHA" \
      "1" "${count}"
  else
    # Build a descriptive failure showing which workflows contributed.
    local detail
    detail="$(python3 - "${FIXTURE}" <<PY
import json, sys
entry_points = set("""${entry_points}""".strip().splitlines())
with open(sys.argv[1]) as f:
    data = json.load(f)
runs = data.get("workflow_runs", [])
matching = [(r.get("name",""), r.get("path","")) for r in runs if r.get("path") in entry_points]
print("; ".join(f"{n} ({p})" for n,p in matching))
PY
)"
    assert_eq "test_single_llm_review_per_sha: exactly one llm-review-class workflow per SHA (got ${count}: ${detail})" \
      "1" "${count}"
  fi
}

test_fixture_present
test_single_llm_review_per_sha

print_summary
