---
id: dso-jfcc
status: open
deps: [dso-7wks, dso-0kz0]
links: []
created: 2026-03-22T02:00:00Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-9l2x
---
# GREEN: Add abbreviated clarification loop to HOOK-INJECTION.md

Add condensed clarification loop to the slim hook-injection version of using-lockpick.

File: plugins/dso/skills/using-lockpick/HOOK-INJECTION.md

Add a condensed ~15-line section covering:
- Confidence test: "one sentence what + why"
- Silent investigation: read code, tickets, git history, CLAUDE.md, memory before asking
- Three probing areas: Intent (what outcome), Scope (how much changes), Risks (side effects/constraints)
- Exit condition: proceed immediately once confident, no explicit confirmation needed

This is the slim version injected at session start — no flowchart, no Red Flags table, no dogfooding guidance.

TDD: Task 1 (dso-7wks) HOOK-INJECTION tests turn GREEN. Full test suite passes.

test-exempt: static assets only — markdown agent guidance, same justification as Task 2.

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] Skill file exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/HOOK-INJECTION.md
- [ ] Full test suite passes (all 13 assertions GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/skills/test-using-lockpick-clarification.sh

