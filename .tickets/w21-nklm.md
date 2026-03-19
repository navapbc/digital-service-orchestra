---
id: w21-nklm
status: open
deps: [w21-kzkp]
links: []
created: 2026-03-19T05:43:22Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-1m1i
---
# Update using-lockpick HOOK-INJECTION.md to route bug fixes to dso:fix-bug

## Description

Update the "Skill Priority" and "Skill Types" sections of `plugins/dso/skills/using-lockpick/HOOK-INJECTION.md` to route bug-fix requests to `/dso:fix-bug` instead of `tdd-workflow`, while keeping `tdd-workflow` as the TDD skill for new feature development. This mirrors the changes in Task 2 (SKILL.md).

## TDD Requirement

Task w21-kzkp (RED) must confirm the old state before this task runs.

## Implementation Steps

1. Open `plugins/dso/skills/using-lockpick/HOOK-INJECTION.md`
2. In the **Skill Priority** section (currently line ~24), update:
   - FROM: `Process skills first (\`/dso:brainstorm\`, \`tdd-workflow\`) — then implementation skills (\`/dso:sprint\`, \`/dso:implementation-plan\`).`
   - TO: `Process skills first (\`/dso:brainstorm\`, \`/dso:fix-bug\` for bug fixes, \`/dso:tdd-workflow\` for new feature TDD) — then implementation skills (\`/dso:sprint\`, \`/dso:implementation-plan\`).`
3. In the **Skill Types** section (currently line ~28), update:
   - FROM: `**Rigid** (\`tdd-workflow\`, \`verification-before-completion\`): follow exactly.`
   - TO: `**Rigid** (\`/dso:fix-bug\`, \`/dso:tdd-workflow\`, \`verification-before-completion\`): follow exactly.`
4. Run `bash plugins/dso/scripts/check-skill-refs.sh` to confirm no unqualified skill refs

## Files
- `plugins/dso/skills/using-lockpick/HOOK-INJECTION.md` (edit)

## Notes
- Apply identical changes to those made in Task 2 (w21-qykc) for SKILL.md — consistency between the two files is required per the Maintainability consideration in the story
- The skill namespace qualification policy requires `/dso:fix-bug` not just `fix-bug`

## ACCEPTANCE CRITERIA

- [ ] grep confirms `dso:fix-bug` is now present in Skill Priority section of HOOK-INJECTION.md
  Verify: grep -q 'fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/HOOK-INJECTION.md
- [ ] grep confirms routing distinguishes bug fixes (dso:fix-bug) from new feature TDD (tdd-workflow) in Skill Priority section
  Verify: grep -q 'fix-bug.*tdd-workflow\|fix.bug.*new feature\|bug fix.*fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/HOOK-INJECTION.md
- [ ] `bash plugins/dso/scripts/check-skill-refs.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/check-skill-refs.sh
- [ ] Skill Priority and Skill Types sections in HOOK-INJECTION.md match the routing text in SKILL.md
  Verify: diff <(grep -A2 'Skill Priority' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md) <(grep -A2 'Skill Priority' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/HOOK-INJECTION.md)
