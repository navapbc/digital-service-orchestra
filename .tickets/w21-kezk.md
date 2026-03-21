---
id: w21-kezk
status: closed
deps: []
links: []
created: 2026-03-21T21:05:07Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-2j6u
---
# As a practitioner invoking /dso:resolve-conflicts, I receive conflict classifications from a dedicated conflict-analyzer agent

## Description

**What**: Create the `dso:conflict-analyzer` dedicated agent definition and update resolve-conflicts to dispatch conflict analysis via the named agent instead of embedding the classification prompt inline in SKILL.md.
**Why**: Promoting conflict classification logic to a dedicated agent definition improves output format compliance (structured per-file classification with TRIVIAL/SEMANTIC/AMBIGUOUS, resolution, explanation, and confidence fields).
**Scope**:
- IN: Create `plugins/dso/agents/conflict-analyzer.md` with YAML frontmatter (name: conflict-analyzer, model: sonnet, tools: Bash, Read, Glob, Grep) and markdown body. Update resolve-conflicts SKILL.md to dispatch via `subagent_type: dso:conflict-analyzer`.
- OUT: Complexity evaluator (separate agent, w21-1as4/w21-cw8j). `semantic-conflict-check.py` (different mechanism, not part of this extraction).

## Done Definitions

- When this story is complete, `plugins/dso/agents/conflict-analyzer.md` exists with YAML frontmatter (name: conflict-analyzer, model: sonnet, tools: Bash, Read, Glob, Grep) and a markdown body containing conflict classification criteria (TRIVIAL/SEMANTIC/AMBIGUOUS), per-file output format, and confidence scoring
  ← Satisfies: "Practitioners invoking /dso:resolve-conflicts receive conflict classifications from dso:conflict-analyzer"
- When this story is complete, resolve-conflicts dispatches conflict analysis via `subagent_type: dso:conflict-analyzer` instead of embedding the prompt inline in SKILL.md
  ← Satisfies: "dispatch conflict analysis via subagent_type: dso:conflict-analyzer"
- When this story is complete, the agent definition's per-file output contains all required fields: file path, classification (TRIVIAL/SEMANTIC/AMBIGUOUS), proposed resolution, explanation, and confidence (HIGH/MEDIUM/LOW)
  ← Satisfies: "per-file output containing: file path, classification, proposed resolution, explanation, and confidence"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Testing] Verify agent produces per-file output with all required fields — incomplete output breaks resolve-conflicts' auto-resolution logic
- [Reliability] If named agent file is missing, resolve-conflicts needs documented fallback to inline classification

## ACCEPTANCE CRITERIA

- [ ] `plugins/dso/agents/conflict-analyzer.md` exists with YAML frontmatter containing name, model, and tools fields
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/agents/conflict-analyzer.md
- [ ] Agent definition contains TRIVIAL/SEMANTIC/AMBIGUOUS classification criteria
  Verify: grep -q "TRIVIAL.*SEMANTIC.*AMBIGUOUS\|TRIVIAL\|SEMANTIC\|AMBIGUOUS" $(git rev-parse --show-toplevel)/plugins/dso/agents/conflict-analyzer.md
- [ ] Agent definition contains per-file output format with all required fields
  Verify: grep -q "confidence" $(git rev-parse --show-toplevel)/plugins/dso/agents/conflict-analyzer.md
- [ ] resolve-conflicts SKILL.md references `dso:conflict-analyzer` subagent_type
  Verify: grep -q "conflict-analyzer" $(git rev-parse --show-toplevel)/plugins/dso/skills/resolve-conflicts/SKILL.md
- [ ] Unit tests exist and pass for agent definition structure validation
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_conflict_analyzer_agent.py || test -f $(git rev-parse --show-toplevel)/tests/skills/test_conflict_analyzer_agent.sh


## Notes

**2026-03-21T21:49:15Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T21:49:52Z**

CHECKPOINT 2/6: Code patterns understood ✓ — resolve-conflicts/SKILL.md Step 2 has inline classification prompt dispatched via general-purpose sonnet sub-agent; agents/ directory does not yet exist; complexity-evaluator.md in shared/prompts is an example of agent content format

**2026-03-21T21:51:39Z**

CHECKPOINT 3/6: Tests written ✓ — 18 RED tests in tests/skills/test_conflict_analyzer_agent.py; 1 test pre-passes (subagent_type already in skill); all agent-existence and content tests are RED

**2026-03-21T21:52:54Z**

CHECKPOINT 4/6: Implementation complete ✓ — created plugins/dso/agents/conflict-analyzer.md with YAML frontmatter (name, model: sonnet, tools: Bash/Read/Glob/Grep) and markdown body with TRIVIAL/SEMANTIC/AMBIGUOUS criteria, per-file output format, confidence scoring; updated resolve-conflicts SKILL.md Step 2 to dispatch via subagent_type: dso:conflict-analyzer with fallback documentation

**2026-03-21T21:52:59Z**

CHECKPOINT 5/6: Validation passed ✓ — 19/19 tests passing in tests/skills/test_conflict_analyzer_agent.py

**2026-03-21T21:53:20Z**

CHECKPOINT 6/6: Done ✓ — All 5 AC criteria verified PASS; 19/19 new tests pass; 3/3 existing resolve-conflicts tests unbroken
