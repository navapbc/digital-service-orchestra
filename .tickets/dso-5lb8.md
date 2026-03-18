---
id: dso-5lb8
status: open
deps: []
links: []
created: 2026-03-18T17:15:25Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-fel5
---
# As a DSO developer, the merge workflow and health check have checkpoint phases removed


## Notes

**2026-03-18T17:17:11Z**

**What:** Remove `_phase_checkpoint_verify` function and all its contents from `scripts/merge-to-main.sh`, remove `checkpoint_verify` from the `_ALL_PHASES` array, and remove its call in the main execution sequence. The phase is dropped entirely — not renamed or absorbed. Remove `.checkpoint-pending-rollback` and `.checkpoint-needs-review` cleanup logic from `scripts/health-check.sh`.

**Why:** The checkpoint_verify phase checked that a `.checkpoint-needs-review` sentinel written by the hook had been reviewed and deleted before merging. With the hook removed, this sentinel is never written, making the phase permanently vacuous.

**Scope:**
- IN: Epic crits 24-25
- OUT: Updating the test files that cover these scripts (S5); documentation updates (S6)

**Done Definitions:**
- When complete, `scripts/merge-to-main.sh` contains no `_phase_checkpoint_verify` function and `checkpoint_verify` does not appear in `_ALL_PHASES` ← Epic crit 24
- When complete, `scripts/health-check.sh` contains no cleanup logic for `.checkpoint-pending-rollback` or `.checkpoint-needs-review` ← Epic crit 25

**Considerations:**
- [Reliability] Verify `_ALL_PHASES` array and any phase-count assertions in the test suite remain consistent after removal

**2026-03-18T17:26:09Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
