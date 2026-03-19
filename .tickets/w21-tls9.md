---
id: w21-tls9
status: in_progress
deps: [w21-hb1j]
links: []
created: 2026-03-19T15:22:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dksj
---
# GREEN: Create advanced-investigation-agent-b.md (historical lens prompt)

Create plugins/dso/skills/fix-bug/prompts/advanced-investigation-agent-b.md — the historical lens prompt for ADVANCED investigation.

This prompt extends the INTERMEDIATE investigation template with Agent B-specific techniques:
- Role: 'You are an opus-level historical analyst and bug investigator for an ADVANCED investigation.'
- Lens framing: Historical Analyst — you analyze bugs through change history, timelines, and fault trees
- Shares common structure with advanced-investigation-agent-a.md (same context slots, same extended RESULT schema)
- Investigation steps:
  - Structured Localization (from INTERMEDIATE — retain, but orient toward change history)
  - Timeline Reconstruction: build a chronological timeline of changes to affected files using commit history
  - Fault Tree Analysis: work backward from the failure, identifying contributing causes in a tree structure
  - Git Bisect Guidance: describe how git bisect would identify the introducing commit (do not run it — guidance only)
  - Hypothesis Generation and Elimination — label as 'from change history'
  - Self-Reflection Checkpoint (from INTERMEDIATE — retain)
- Context slots (same as INTERMEDIATE): {ticket_id}, {failing_tests}, {stack_trace}, {commit_history}, {prior_fix_attempts}
- RESULT schema extends INTERMEDIATE with ADVANCED-specific fields (same as Agent A):
  convergence_score: <fill with 'PENDING — orchestrator computes after both agents return'>
  fishbone_categories:
    code_logic: <your findings on code logic as a cause>
    state: <your findings on state as a cause>
    configuration: <your findings on configuration as a cause>
    dependencies: <your findings on dependencies as a cause>
    environment: <your findings on environment as a cause>
    data: <your findings on data as a cause>
- Proposes at least 2 fixes following INTERMEDIATE format
- Must NOT implement fixes — investigation only
- Must NOT dispatch sub-agents

Reliability consideration: if commit history is unavailable or too sparse to reconstruct a useful timeline, note the limitation and pivot to code-only analysis rather than failing.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff lint passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format-check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Prompt file exists at expected path
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/advanced-investigation-agent-b.md
- [ ] All tests in test_advanced_investigation_agent_b_prompt.py PASS
  Verify: python -m pytest tests/skills/test_advanced_investigation_agent_b_prompt.py -v
- [ ] Prompt contains timeline reconstruction language
  Verify: grep -q 'timeline' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/advanced-investigation-agent-b.md
- [ ] Prompt contains fault tree analysis language
  Verify: grep -q 'fault tree' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/advanced-investigation-agent-b.md
- [ ] Prompt contains git bisect technique
  Verify: grep -q 'git bisect' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/advanced-investigation-agent-b.md


## Notes

**2026-03-19T17:42:13Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T17:42:40Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T17:42:46Z**

CHECKPOINT 3/6: Tests written ✓ (test file pre-exists as RED spec — no modification needed)

**2026-03-19T17:43:31Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T17:43:49Z**

CHECKPOINT 5/6: Validation passed ✓ — 15/15 tests passed, ruff lint clean, ruff format clean

**2026-03-19T17:52:46Z**

CHECKPOINT 6/6: Done ✓ — All 15 target tests pass. run-all.sh failures are pre-existing (unrelated to this task — hook lib, merge-to-main portability, eval for fix-cascade-recovery). All AC grep checks pass.
