---
id: dso-2bmc
status: closed
deps: []
links: []
created: 2026-03-22T17:42:21Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-s12s
---
# Add descriptive agent name guidance to /dso:debug-everything dispatch points

Add explicit guidance at the Phase 5 sub-agent dispatch point in plugins/dso/skills/debug-everything/SKILL.md instructing the orchestrator to derive the Agent tool's description field from the ticket title (3-5 word summary) instead of using the ticket ID.

Dispatch point to update (1 total):
1. Phase 5 (~line 506): fix task sub-agent launch

Canonical sentence to add:
**Agent description**: Derive from the ticket title — a 3-5 word human-readable summary (e.g., Fix review gate hash, not dso-abc1).

TDD Exemption: criterion 3 per implementation-plan/SKILL.md TDD Exemption Criteria (static assets only — Markdown files, no conditional logic, no executable code).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Debug-everything dispatch instructions include the canonical description guidance
  Verify: grep -c 'Agent description.*Derive from the ticket title' $(git rev-parse --show-toplevel)/plugins/dso/skills/debug-everything/SKILL.md | awk '{exit ($1 < 1)}'
- [ ] Post-merge smoke test: next sprint or debug-everything session dispatching a generic sub-agent displays a human-readable description in the status line
  Verify: manual observation during next session run

## Notes

<!-- note-id: wd57qv6s -->
<!-- timestamp: 2026-03-22T21:38:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: ymf8rvyu -->
<!-- timestamp: 2026-03-22T21:39:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: v7xudr78 -->
<!-- timestamp: 2026-03-22T21:39:27Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓

<!-- note-id: jx9n0i4y -->
<!-- timestamp: 2026-03-22T21:39:32Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: eixggb0q -->
<!-- timestamp: 2026-03-22T21:48:36Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: uqzdghzh -->
<!-- timestamp: 2026-03-22T21:48:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
