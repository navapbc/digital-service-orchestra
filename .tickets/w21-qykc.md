---
id: w21-qykc
status: open
deps: [w21-qsh6]
links: []
created: 2026-03-19T05:43:21Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-1m1i
---
# Update using-lockpick SKILL.md to route bug fixes to dso:fix-bug

## Description

Update the "Skill Priority" and "Skill Types" sections of `plugins/dso/skills/using-lockpick/SKILL.md` to route bug-fix requests to `/dso:fix-bug` instead of `tdd-workflow`, while keeping `tdd-workflow` as the TDD skill for new feature development.

## TDD Requirement

Task w21-qsh6 (RED) must confirm the old state before this task runs.

## Implementation Steps

1. Open `plugins/dso/skills/using-lockpick/SKILL.md`
2. In the **Skill Priority** section (currently line ~73), update:
   - FROM: `Process skills first (\`/dso:brainstorm\`, \`tdd-workflow\`) — then implementation skills (\`/dso:sprint\`, \`/dso:implementation-plan\`).`
   - TO: `Process skills first (\`/dso:brainstorm\`, \`/dso:fix-bug\` for bug fixes, \`/dso:tdd-workflow\` for new feature TDD) — then implementation skills (\`/dso:sprint\`, \`/dso:implementation-plan\`).`
3. In the **Skill Types** section (currently line ~77), update:
   - FROM: `**Rigid** (\`tdd-workflow\`, \`verification-before-completion\`): follow exactly.`
   - TO: `**Rigid** (\`/dso:fix-bug\`, \`/dso:tdd-workflow\`, \`verification-before-completion\`): follow exactly.`
4. In the **Red Flags** table — NO change needed (those rows discuss checking for skills in general, not routing)
5. Run `bash plugins/dso/scripts/check-skill-refs.sh` to confirm no unqualified skill refs

## Files
- `plugins/dso/skills/using-lockpick/SKILL.md` (edit)

## Notes
- The `tdd-workflow` skill is NOT deprecated for new feature TDD — only for bug fixes
- Preserve the existing skill flow diagram (digraph) unchanged
- The skill namespace qualification policy requires `/dso:fix-bug` not just `fix-bug`

## ACCEPTANCE CRITERIA

- [ ] grep confirms `dso:fix-bug` is now present in Skill Priority section of using-lockpick SKILL.md
  Verify: grep -q 'fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md
- [ ] grep confirms routing distinguishes bug fixes (dso:fix-bug) from new feature TDD (tdd-workflow) in Skill Priority section
  Verify: grep -q 'fix-bug.*tdd-workflow\|fix.bug.*new feature\|bug fix.*fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md
- [ ] `bash plugins/dso/scripts/check-skill-refs.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/check-skill-refs.sh
- [ ] File contains no bare `tdd-workflow` unqualified reference used for bug-fix routing
  Verify: ! grep -q "^Process skills first.*\`tdd-workflow\`" $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md
