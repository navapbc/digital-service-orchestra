---
id: w21-rtmm
status: open
deps: [w21-pjhx, w21-x0t4, w21-tls9]
links: []
created: 2026-03-19T15:22:47Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dksj
---
# GREEN: Update SKILL.md ADVANCED section with prompt template references and context assembly slots

Update the ADVANCED Investigation section in plugins/dso/skills/fix-bug/SKILL.md to add:

1. Prompt template references for both agents (like BASIC/INTERMEDIATE sections):
   - Agent A uses: prompts/advanced-investigation-agent-a.md
   - Agent B uses: prompts/advanced-investigation-agent-b.md

2. Context assembly slots table (same slots as INTERMEDIATE, applied to both agents):
   | Slot | Source |
   |------|--------|
   | {ticket_id} | The bug ticket ID |
   | {failing_tests} | Output of $TEST_CMD |
   | {stack_trace} | Stack trace from test output or error logs |
   | {commit_history} | Output of git log --oneline -20 -- <affected-files> |
   | {prior_fix_attempts} | Ticket notes with previous fix attempt records |

3. Note that both agents run concurrently (both dispatched before either result is awaited)

4. Convergence scoring instructions for the orchestrator:
   - Compare Agent A and Agent B ROOT_CAUSE fields
   - If they agree (same or semantically equivalent root cause): convergence_score = 2, confidence elevated
   - If they partially agree (overlapping cause category): convergence_score = 1, confidence moderate
   - If they diverge: convergence_score = 0, proceed to fishbone synthesis

5. Fishbone synthesis instructions:
   - For each fishbone category (Code Logic, State, Configuration, Dependencies, Environment, Data), merge both agents' findings
   - The synthesized fishbone becomes the orchestrator's unified root cause report

The existing description of Agent A/B techniques and fishbone categories is already in SKILL.md — do NOT remove or rewrite it. Only ADD the prompt references, context slots table, convergence scoring algorithm, and fishbone synthesis instructions.

TDD Requirement (GREEN): After editing, run python -m pytest tests/skills/test_fix_bug_skill.py::TestAdvancedInvestigationSkillIntegration -v and confirm all tests PASS.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff lint passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format-check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] SKILL.md references advanced-investigation-agent-a.md
  Verify: grep -q 'advanced-investigation-agent-a.md' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md references advanced-investigation-agent-b.md
  Verify: grep -q 'advanced-investigation-agent-b.md' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] TestAdvancedInvestigationSkillIntegration tests PASS
  Verify: python -m pytest tests/skills/test_fix_bug_skill.py::TestAdvancedInvestigationSkillIntegration -v
- [ ] Full test_fix_bug_skill.py suite still passes
  Verify: python -m pytest tests/skills/test_fix_bug_skill.py -v

