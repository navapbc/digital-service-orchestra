---
id: dso-bxng
status: open
deps: []
links: []
created: 2026-03-21T23:20:06Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w21-ovpn
---
# As a DSO practitioner, the Standard tier sonnet reviewer applies full 5-dimension checklists with researched sub-criteria


## Notes

<!-- note-id: 2k8hj2b0 -->
<!-- timestamp: 2026-03-21T23:21:05Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Description

**What**: Create the reviewer-delta-standard.md checklist for the Standard tier sonnet reviewer with full 5-dimension coverage and researched sub-criteria.

**Why**: Standard tier handles ~30-40% of reviews. This is the most common reviewer and needs comprehensive criteria across all dimensions. Condensed ticket context reduces false positives without exhausting context budget.

## Acceptance Criteria

- When this story is complete, reviewer-delta-standard.md contains sub-criteria for all 5 dimensions:
  - Correctness: edge cases/failure states with escape hatch, race conditions in async operations, silent failures, tolerance/assertion weakening, over-engineering/YAGNI
  - Verification: behavior-driven not implementation-driven tests, test-code correspondence in same changeset, assertion quality (meaningful vs trivial), arrange-act-assert structure, test smells (naming, fixture bloat)
  - Hygiene: type system escape hatches without justification, nesting depth >2 levels (suggest early returns/extraction), dead code, suppression scrutiny (noqa/type:ignore with justifying comments), explicit exclusion of linter-catchable issues
  - Design: SOLID adherence, architectural pattern adherence, correct file/folder placement, Rule of Three duplication via similarity pipeline, coupling/dependency direction, reuse of existing utilities
  - Maintainability: codebase consistency (local patterns — error handling style, return type patterns, abstraction level — not linter rules), clear and accurate naming (non-descriptive AND inaccurate), comments explain why not what, doc correspondence for public interface changes (minor severity — only when specific existing doc artifact is stale)
- When this story is complete, the checklist includes anti-shortcut distribution: noqa/type:ignore -> hygiene, skipped tests -> verification, tolerances/assertions -> correctness
- When this story is complete, consolidation findings are severity=minor with orchestrator ticket creation
- When this story is complete, the checklist includes ticket context instructions: use condensed summary (title + acceptance criteria) when available; do not block on missing ticket context
- When this story is complete, build-review-agents.sh regenerates the standard reviewer agent successfully

## Research Sources
Google engineering practices, OWASP, test smell literature, 5 Claude Code review plugins (Anthropic official, Claude Command Suite, claude-code-skills, claude-code-showcase, wshobson commands)

