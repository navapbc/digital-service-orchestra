---
id: dso-jneo
status: closed
deps: [dso-l19q, dso-5lb8]
links: []
created: 2026-03-18T17:15:25Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-fel5
---
# As a DSO developer, shared test files no longer assert checkpoint behaviors


## Notes

**2026-03-18T17:17:11Z**

**What:** Update shared test files that contain checkpoint assertions alongside non-checkpoint tests: (1) remove `pre-compact-checkpoint.sh` from the registered-hooks array in `tests/hooks/test-standalone-hooks-no-relative-paths.sh`; (2) update or remove checkpoint_verify assertions from `tests/scripts/test-merge-to-main.sh`; (3) update or remove checkpoint cleanup assertions from `tests/scripts/test-health-check.sh`; (4) remove Group 6 (WIP/pre-compact commit exemptions) from `tests/hooks/test-test-failure-guard.sh`; (5) remove checkpoint sentinel test group from `tests/hooks/test-behavioral-equivalence-allowlist.sh`; (6) scan and update any other test files matching criterion 28c catch-all. After all updates, run `bash tests/run-all.sh` to confirm clean pass.

**Why:** These shared test files exercise behaviors being changed (hook registration, merge phases, test-failure guard exemptions). Leaving their checkpoint assertions in place causes test failures once S1-S3 land.

**Scope:**
- IN: Epic crits 28, 28a, 28b, 28c; GAP-9 (test-test-failure-guard.sh Group 6, test-behavioral-equivalence-allowlist.sh sentinel section)
- OUT: Dedicated checkpoint test file deletions (S4)

**Done Definitions:**
- When complete, `bash tests/run-all.sh` passes with exit 0 ← Epic crits 34, 35
- When complete, `grep -r checkpoint_verify tests/` returns no matches outside of the catch-all scan scope
- When complete, `tests/hooks/test-standalone-hooks-no-relative-paths.sh` contains no reference to `pre-compact-checkpoint.sh` ← Epic crit 28
