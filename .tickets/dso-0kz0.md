---
id: dso-0kz0
status: closed
deps: [dso-7wks]
links: []
created: 2026-03-22T01:59:48Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-9l2x
---
# GREEN: Add clarification loop section to SKILL.md

Add the clarification loop section to the full using-lockpick skill file.

File: plugins/dso/skills/using-lockpick/SKILL.md

Add after "## User Instructions" section:
- ## When No Skill Matches — the clarification loop section
- Silent Investigation: agent reads relevant sources (code, tickets via tk show, git history, CLAUDE.md, memory) before asking user
- Confidence Test: "one sentence what + why" — if agent can articulate what it will do and why in a single declarative statement, proceed; otherwise enter loop
- Clarification Loop: One question per message, multiple-choice preferred, "tell me more" follow-ups. Three labeled probing areas: (a) Intent — what outcome the user wants, (b) Scope — how much should change, (c) Risks — side effects or constraints. Exit as soon as confidence test passes.
- Proceed: Once confident, proceed immediately without requesting explicit confirmation
- Dogfooding Evaluation: Define "intent match" (agent's final action matches user intent on first attempt). Team logs each clarification loop entry and scores intent-match. Target: 80% across 20+ interactions.

TDD: Task 1 (dso-7wks) tests turn GREEN after this edit.

test-exempt: static assets only — markdown agent guidance with no executable assertion possible for runtime LLM behavior. Structural presence verified by Task 1 tests. Runtime behavioral compliance validated by criterion 6 dogfooding.

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] Skill file exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md
- [ ] SKILL.md contains "## When No Skill Matches" heading
  Verify: grep -q '## When No Skill Matches' $(git rev-parse --show-toplevel)/plugins/dso/skills/using-lockpick/SKILL.md
- [ ] Task 1 SKILL.md tests pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/skills/test-using-lockpick-clarification.sh 2>&1 | grep -q 'FAIL' && exit 1 || true


## Notes

**2026-03-22T03:08:22Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T03:08:35Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T03:08:35Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T03:09:18Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T03:09:18Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T03:16:05Z**

CHECKPOINT 6/6: Done ✓

**2026-03-22T03:19:08Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/skills/using-lockpick/SKILL.md. Tests: 10 pass (SKILL.md), 3 fail (HOOK-INJECTION.md — expected).
