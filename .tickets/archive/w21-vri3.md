---
id: w21-vri3
status: closed
deps: [w21-mx4t]
links: []
created: 2026-03-19T05:43:22Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-1m1i
---
# Update sprint SKILL.md validation failure section to reference dso:fix-bug

## Description

Update the Run Validation Gate section of `plugins/dso/skills/sprint/SKILL.md` to add an explicit reference to `/dso:fix-bug` for single-bug validation failures encountered during epic execution. Currently this section only references `error-debugging:error-detective` sub-agents. The story requires practitioners see `/dso:fix-bug` as the routing path for single validation failures.

## TDD Requirement

Task w21-mx4t (RED) must confirm the baseline (dso:fix-bug absent) before this task runs.

## Implementation Steps

1. Open `plugins/dso/skills/sprint/SKILL.md`
2. Find the **Run Validation Gate** section (around line 183), which currently reads:
   ```
   **If validation fails**: Dispatch an `error-debugging:error-detective` sub-agent (model: `sonnet`) with the validation output to diagnose and fix the specific failing categories. Do NOT invoke `/dso:debug-everything` — it is a separate workflow that resolves all project bugs, not just sprint-scoped failures. Do NOT proceed to the Preplanning Gate until validation passes.
   ```
3. Update this section to route single-bug failures to `/dso:fix-bug`:
   ```
   **If validation fails**:
   - **Single bug/test failure**: Invoke `/dso:fix-bug` with the failing test output — it classifies the bug, selects the appropriate investigation path, and fixes it with TDD discipline. Do NOT use `/dso:tdd-workflow` for bug fixes.
   - **Multiple failures or unclear root cause**: Dispatch an `error-debugging:error-detective` sub-agent (model: `sonnet`) with the validation output to diagnose and fix the specific failing categories. Do NOT invoke `/dso:debug-everything` — it is a separate workflow that resolves all project bugs, not just sprint-scoped failures.
   - Do NOT proceed to the Preplanning Gate until validation passes.
   ```
4. Run `bash plugins/dso/scripts/check-skill-refs.sh` to confirm no unqualified skill refs

## Files
- `plugins/dso/skills/sprint/SKILL.md` (edit, around line 183)

## Notes
- This is a safeguard file (plugins/dso/skills/**) — requires user approval before execution per CLAUDE.md Critical Rule #20
- The routing distinction is: single bug → `/dso:fix-bug`, multiple/unclear → `error-debugging:error-detective`
- This matches the using-lockpick routing pattern (single bug → dso:fix-bug, multiple → debug-everything)

## ACCEPTANCE CRITERIA

- [ ] grep confirms `/dso:fix-bug` is now referenced in the validation failure section of sprint SKILL.md
  Verify: grep -q 'fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md
- [ ] grep confirms routing distinguishes single bug (dso:fix-bug) from multiple failures (error-detective) in validation section
  Verify: grep -q 'fix-bug.*single\|Single.*fix-bug\|single.*fix.bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md
- [ ] grep confirms `tdd-workflow` is NOT referenced in sprint SKILL.md (validation uses fix-bug, not tdd-workflow)
  Verify: ! grep -q 'tdd-workflow' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md
- [ ] `bash plugins/dso/scripts/check-skill-refs.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/check-skill-refs.sh

**2026-03-19T06:02:39Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T06:02:55Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T06:03:28Z**

CHECKPOINT 6/6: Done ✓
