#!/usr/bin/env bash
# tests/scripts/test-no-duplicate-checks-per-sha.sh
#
# Behavioral test for epic f691-681e-0db9-4260 SC3:
#   "No SHA produces more than one workflow run with the same check-context
#    name across all check suites."
#
# Given:  a recorded fixture of `gh api repos/.../actions/runs` representing
#         workflow_run API responses that may span multiple check_suite_ids and
#         multiple run_attempt values.
# When:   entries are grouped by (head_sha, check_suite_id) and the latest
#         run_attempt is selected per group (re-runs supersede earlier attempts),
#         then uniqueness of check-context name (the `name` field) is asserted
#         within each head_sha.
# Then:   no head_sha should produce two latest-attempt entries with the same
#         check-context name.
#
# RED:    The RED fixture contains a SHA where two different check_suite_ids
#         both have a latest-attempt run with name "LLM Review". The duplicate
#         is detected and the test exits non-zero.
# GREEN:  The GREEN fixture has the same (head_sha, check_suite_id) pair with
#         two run_attempt values (exercises re-run selection), but no duplicate
#         check-context names per SHA across suite groups. The test exits 0.
#
# This test complements test-single-llm-review-per-sha.sh, which checks the
# NARROWER case (only LLM-review-class entry-point workflows, identified by
# the workflow path). This test checks the BROADER invariant: no duplicate
# check-context name for any name across all check suites for a given SHA.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${REPO_ROOT}/tests/lib/assert.sh"

GREEN_FIXTURE="${REPO_ROOT}/tests/fixtures/workflow-runs/no-duplicate-checks-GREEN-fixture.json"
RED_FIXTURE="${REPO_ROOT}/tests/fixtures/workflow-runs/no-duplicate-checks-RED-fixture.json"

# ---------------------------------------------------------------------------
# Helper: given a fixture path, group workflow_run entries by (head_sha,
# check_suite_id), select the highest run_attempt per group, then return
# the duplicate check-context names (name field) found per head_sha among
# those latest-attempt entries.
#
# Output: one line per duplicate, format: "<head_sha> <name>"
# Exit 0 always (duplicate detection is the caller's responsibility).
# ---------------------------------------------------------------------------
find_duplicate_check_names() {
  local fixture="$1"
  python3 - "${fixture}" <<'PY'
import json, sys, collections

with open(sys.argv[1]) as f:
    data = json.load(f)

runs = data.get("workflow_runs", [])

# Step 1: group by (head_sha, check_suite_id); keep highest run_attempt
group_key = lambda r: (r.get("head_sha", ""), str(r.get("check_suite_id", "")))
latest = {}
for run in runs:
    key = group_key(run)
    attempt = run.get("run_attempt", 0)
    if key not in latest or attempt > latest[key].get("run_attempt", 0):
        latest[key] = run

# Step 2: for each head_sha, collect the check-context names from latest-attempt entries
sha_names = collections.defaultdict(list)
for (head_sha, _suite_id), run in latest.items():
    name = run.get("name", "")
    sha_names[head_sha].append(name)

# Step 3: detect duplicates within each SHA
for head_sha, names in sorted(sha_names.items()):
    seen = set()
    for name in names:
        if name in seen:
            print(f"{head_sha} {name}")
        seen.add(name)
PY
}

# ---------------------------------------------------------------------------
# test_fixtures_present
# ---------------------------------------------------------------------------
test_fixtures_present() {
  if [ -f "${GREEN_FIXTURE}" ]; then
    assert_eq "test_fixtures_present: GREEN fixture exists" "OK" "OK"
  else
    assert_eq "test_fixtures_present: GREEN fixture exists" "OK" "MISSING: ${GREEN_FIXTURE}"
  fi

  if [ -f "${RED_FIXTURE}" ]; then
    assert_eq "test_fixtures_present: RED fixture exists" "OK" "OK"
  else
    assert_eq "test_fixtures_present: RED fixture exists" "OK" "MISSING: ${RED_FIXTURE}"
  fi
}

# ---------------------------------------------------------------------------
# test_latest_attempt_selection
# Verifies the grouping logic resolves the highest run_attempt for a given
# (head_sha, check_suite_id) pair. The GREEN fixture has suite 9001 with
# run_attempt 1 (failure) and run_attempt 2 (success) — only attempt 2
# should appear in the latest set.
# ---------------------------------------------------------------------------
test_latest_attempt_selection() {
  if [ ! -f "${GREEN_FIXTURE}" ]; then
    assert_eq "test_latest_attempt_selection: fixture present" "OK" "MISSING"
    return
  fi

  # Count how many times suite 9001 appears after latest-attempt selection.
  # Should be exactly 1 (run_attempt=2 wins over run_attempt=1).
  local suite_count
  suite_count="$(python3 - "${GREEN_FIXTURE}" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

runs = data.get("workflow_runs", [])
group_key = lambda r: (r.get("head_sha", ""), str(r.get("check_suite_id", "")))
latest = {}
for run in runs:
    key = group_key(run)
    attempt = run.get("run_attempt", 0)
    if key not in latest or attempt > latest[key].get("run_attempt", 0):
        latest[key] = run

# Count entries for check_suite_id 9001
count = sum(1 for (_sha, sid) in latest if sid == "9001")
print(count)
PY
)"

  assert_eq \
    "test_latest_attempt_selection: suite 9001 represented exactly once after run_attempt dedup" \
    "1" "${suite_count}"

  # Also confirm the winning attempt is 2 (highest)
  local winning_attempt
  winning_attempt="$(python3 - "${GREEN_FIXTURE}" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

runs = data.get("workflow_runs", [])
group_key = lambda r: (r.get("head_sha", ""), str(r.get("check_suite_id", "")))
latest = {}
for run in runs:
    key = group_key(run)
    attempt = run.get("run_attempt", 0)
    if key not in latest or attempt > latest[key].get("run_attempt", 0):
        latest[key] = run

for (_sha, sid), run in latest.items():
    if sid == "9001":
        print(run.get("run_attempt", "?"))
PY
)"

  assert_eq \
    "test_latest_attempt_selection: winning run_attempt for suite 9001 is 2" \
    "2" "${winning_attempt}"
}

# ---------------------------------------------------------------------------
# test_no_duplicate_check_names_green
# Assert that the GREEN fixture produces zero duplicates.
# ---------------------------------------------------------------------------
test_no_duplicate_check_names_green() {
  if [ ! -f "${GREEN_FIXTURE}" ]; then
    assert_eq "test_no_duplicate_check_names_green: fixture present" "OK" "MISSING"
    return
  fi

  local duplicates
  duplicates="$(find_duplicate_check_names "${GREEN_FIXTURE}")"

  assert_eq \
    "test_no_duplicate_check_names_green: no duplicate check-context names per SHA (GREEN fixture)" \
    "" "${duplicates}"
}

# ---------------------------------------------------------------------------
# test_red_fixture_has_duplicate
# Assert that the RED fixture DOES produce at least one duplicate — this
# demonstrates that the detection logic catches the failure case.
# The test's overall pass/fail is driven by the GREEN fixture; this sub-test
# verifies the detector is not vacuously true.
# ---------------------------------------------------------------------------
test_red_fixture_has_duplicate() {
  if [ ! -f "${RED_FIXTURE}" ]; then
    assert_eq "test_red_fixture_has_duplicate: fixture present" "OK" "MISSING"
    return
  fi

  local duplicates
  duplicates="$(find_duplicate_check_names "${RED_FIXTURE}")"

  # The RED fixture should report at least one duplicate.
  if [ -n "${duplicates}" ]; then
    assert_eq "test_red_fixture_has_duplicate: RED fixture correctly detected as having duplicates" \
      "DETECTED" "DETECTED"
  else
    assert_eq "test_red_fixture_has_duplicate: RED fixture correctly detected as having duplicates" \
      "DETECTED" "NO_DUPLICATES_FOUND (detection logic broken)"
  fi
}

# ---------------------------------------------------------------------------
# test_check_suite_id_grouping
# Confirm that two entries with the same head_sha but different check_suite_ids
# are treated as separate groups (not collapsed). Uses the GREEN fixture where
# head_sha abc123... has suites 9001, 9002, and 9003 each independently.
# ---------------------------------------------------------------------------
test_check_suite_id_grouping() {
  if [ ! -f "${GREEN_FIXTURE}" ]; then
    assert_eq "test_check_suite_id_grouping: fixture present" "OK" "MISSING"
    return
  fi

  local group_count
  group_count="$(python3 - "${GREEN_FIXTURE}" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

runs = data.get("workflow_runs", [])
TARGET_SHA = "abc123def456abc123def456abc123def456abc1"

group_key = lambda r: (r.get("head_sha", ""), str(r.get("check_suite_id", "")))
latest = {}
for run in runs:
    key = group_key(run)
    attempt = run.get("run_attempt", 0)
    if key not in latest or attempt > latest[key].get("run_attempt", 0):
        latest[key] = run

count = sum(1 for (sha, _sid) in latest if sha == TARGET_SHA)
print(count)
PY
)"

  # abc123 SHA has suites 9001, 9002, 9003 → 3 groups after dedup
  assert_eq \
    "test_check_suite_id_grouping: abc123 SHA produces 3 distinct (sha,suite) groups" \
    "3" "${group_count}"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_fixtures_present
test_latest_attempt_selection
test_no_duplicate_check_names_green
test_red_fixture_has_duplicate
test_check_suite_id_grouping

print_summary
