---
id: w21-ha0r
status: in_progress
deps: [w21-ifgr, w21-n1rq]
links: []
created: 2026-03-21T01:41:33Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w21-p7aa
---
# Update project docs to reflect batched test enforcement

## Description

**What**: One-time edit to CLAUDE.md and SUB-AGENT-BOUNDARIES.md: add broad test commands to the Never Do These list, replace quick-reference/example usage with validate.sh
**Why**: Removes counterproductive guidance that teaches agents about prohibited commands in quick-reference tables and examples — prohibited commands should only appear on explicit prohibition lists
**Scope**:
- IN: CLAUDE.md edits (Never Do These + quick-reference table), SUB-AGENT-BOUNDARIES.md edits
- OUT: Skill prompt optimization (deferred to dso-l2ct, dso-zj3r)

## Done Definitions

- When this story is complete, for make test-unit-only and make test-e2e, grep -n in CLAUDE.md and SUB-AGENT-BOUNDARIES.md returns zero matches outside lines between ### Never Do These and the next ### heading
  ← Satisfies: "CLAUDE.md and SUB-AGENT-BOUNDARIES.md are updated in a one-time edit"

## ACCEPTANCE CRITERIA

- [ ] CLAUDE.md: `make test-unit-only` and `make test-e2e` appear ONLY in the Never Do These section (or equivalent prohibition list)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && count=$(grep -n "make test-unit-only\|make test-e2e" "$REPO_ROOT/CLAUDE.md" | grep -v "Never Do These\|Never.*test\|prohibited\|blocked\|NEVER" | wc -l) && test "$count" -eq 0
- [ ] SUB-AGENT-BOUNDARIES.md: `make test-unit-only` and `make test-e2e` appear ONLY in prohibition context
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && count=$(grep -rn "make test-unit-only\|make test-e2e" "$REPO_ROOT/plugins/dso/docs/SUB-AGENT-BOUNDARIES.md" | grep -v "Never\|prohibited\|blocked\|NEVER\|must not" | wc -l) && test "$count" -eq 0
- [ ] Quick-reference/example usage replaced with validate.sh --ci
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && grep -q "validate.sh --ci" "$REPO_ROOT/CLAUDE.md"

## Considerations

- Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions


## Notes

**2026-03-21T01:41:40Z**

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.

**2026-03-21T02:44:27Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T02:44:53Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T02:44:56Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-21T02:45:33Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T02:46:26Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T02:46:32Z**

CHECKPOINT 6/6: Done ✓
