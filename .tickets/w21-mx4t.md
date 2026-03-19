---
id: w21-mx4t
status: open
deps: []
links: []
created: 2026-03-19T05:43:22Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-1m1i
---
# RED: confirm sprint SKILL.md validation failure section lacks dso:fix-bug reference

## Description

Confirm the CURRENT state of sprint SKILL.md validation failure section (Run Validation Gate, line ~183) does NOT reference `/dso:fix-bug` for single-bug validation failures during epic execution. This establishes the baseline that Task 6 must fix.

Also confirm that `tdd-workflow` is NOT referenced in sprint SKILL.md (sprint never mentioned tdd-workflow — the fix is to ADD a dso:fix-bug reference where practitioners should be directed for single-bug validation failures).

## TDD Requirement (RED phase)

Run the following verification — Check 1 should PASS (confirming dso:fix-bug absent), Check 2 should PASS (confirming tdd-workflow absent):

```bash
SPRINT_SKILL="$(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md"
# Check 1: dso:fix-bug NOT yet present in validation failure section
! grep -q 'fix-bug' "$SPRINT_SKILL" && echo 'RED confirmed: dso:fix-bug not yet referenced in sprint SKILL.md'
# Check 2: tdd-workflow already absent from sprint SKILL.md (not the change to make)
! grep -q 'tdd-workflow' "$SPRINT_SKILL" && echo 'Confirmed: tdd-workflow not in sprint SKILL.md (correct)'
```

After Task 6 is complete, Check 1 should FAIL (dso:fix-bug now present in the validation section).

## Context

The sprint SKILL.md Run Validation Gate (around line 183) currently says:
> "Dispatch an `error-debugging:error-detective` sub-agent... Do NOT invoke `/dso:debug-everything`..."

The story requires adding guidance that single-bug validation failures should route to `/dso:fix-bug` (not just error-detective). Task 6 adds this reference.

## Files
- `plugins/dso/skills/sprint/SKILL.md` (read-only verification)

## Justification for Unit Test Exemption
1. No conditional logic — purely structural text update to a markdown instruction file
2. Any automated test would only detect text presence (change-detector test, not behavior test)
3. Infrastructure-boundary-only — skill instruction markdown files have no business logic

## ACCEPTANCE CRITERIA

- [ ] grep confirms `dso:fix-bug` NOT yet referenced in sprint SKILL.md (pre-fix state)
  Verify: ! grep -q 'fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md
- [ ] grep confirms `tdd-workflow` already absent from sprint SKILL.md
  Verify: ! grep -q 'tdd-workflow' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md
- [ ] `bash plugins/dso/scripts/check-skill-refs.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/check-skill-refs.sh
