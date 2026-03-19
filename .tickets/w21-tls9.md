---
id: w21-tls9
status: open
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

