---
id: w21-qsh6
status: open
deps: []
links: []
created: 2026-03-19T05:43:21Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-1m1i
---
# RED: confirm using-lockpick SKILL.md still routes to tdd-workflow not dso:fix-bug

## Description

Confirm the CURRENT state of using-lockpick SKILL.md shows `tdd-workflow` in the "Skill Priority" and "Skill Types" routing context (not yet replaced with `dso:fix-bug`). This establishes the failing baseline that Task 2 must correct.

## TDD Requirement (RED phase)

Run the following verification — both checks should PASS (confirming old state is present):

```bash
SKILL_FILE="$(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md"
# Check 1: tdd-workflow still present in Skill Priority routing context
grep -q 'brainstorm.*tdd-workflow\|tdd-workflow.*brainstorm' "$SKILL_FILE" && echo 'RED confirmed: old tdd-workflow routing present'
# Check 2: dso:fix-bug NOT yet present in the file
! grep -q 'fix-bug' "$SKILL_FILE" && echo 'RED confirmed: dso:fix-bug not yet referenced'
```

After Task 2 is complete, Check 1 should FAIL (old text removed) and a new check for `fix-bug` should PASS.

## Files
- `plugins/dso/skills/using-lockpick/SKILL.md` (read-only verification)

## Justification for Unit Test Exemption
1. No conditional logic — purely structural text update to a markdown instruction file
2. Any automated test would only detect text presence (change-detector test, not behavior test)
3. Infrastructure-boundary-only — skill instruction markdown files have no business logic

## ACCEPTANCE CRITERIA

- [ ] grep confirms `tdd-workflow` present in Skill Priority routing line of using-lockpick SKILL.md
  Verify: grep -q 'brainstorm.*tdd-workflow\|tdd-workflow.*brainstorm' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md
- [ ] grep confirms `dso:fix-bug` NOT yet present in using-lockpick SKILL.md (pre-fix state)
  Verify: ! grep -q 'fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md
- [ ] `bash plugins/dso/scripts/check-skill-refs.sh` passes (exit 0) — no unqualified skill refs introduced
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/check-skill-refs.sh
