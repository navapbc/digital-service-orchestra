---
id: dso-5rya
status: open
deps: []
links: []
created: 2026-03-22T17:42:14Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-s12s
---
# Add descriptive agent name guidance to /dso:sprint dispatch points

Add explicit guidance at all sub-agent dispatch points in plugins/dso/skills/sprint/SKILL.md instructing the orchestrator to derive the Agent tool's description field from the ticket title (3-5 word summary) instead of using the ticket ID.

Dispatch points to update (3 total):
1. Phase 1 Step 3a (~line 258-262): impl-plan-dispatch for SIMPLE epics
2. Phase 2 Step 2 (~line 377-381): impl-plan-dispatch for stories
3. Phase 5 (~line 662-749): task execution sub-agent launch

Canonical sentence to add at each dispatch point:
**Agent description**: Derive from the ticket title — a 3-5 word human-readable summary (e.g., Fix review gate hash, not dso-abc1).

TDD Exemption: criterion 3 per implementation-plan/SKILL.md TDD Exemption Criteria (static assets only — Markdown files, no conditional logic, no executable code).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] All 3 sub-agent dispatch sections in sprint/SKILL.md include the canonical description guidance
  Verify: grep -c 'Agent description.*Derive from the ticket title' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md | awk '{exit ($1 < 3)}'
- [ ] Post-merge smoke test: next sprint session dispatching a generic sub-agent displays a human-readable description in the status line
  Verify: manual observation during next sprint run
