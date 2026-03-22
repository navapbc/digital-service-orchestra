---
id: w22-wwu2
status: open
deps: []
links: []
created: 2026-03-22T06:45:53Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-5ooy
---
# As a DSO practitioner, code changes touching security-sensitive paths trigger a deterministic overlay signal from the classifier

## Description

**What**: Extend review-complexity-classifier.sh to emit security_overlay and performance_overlay boolean flags alongside the existing tier score.
**Why**: Provides deterministic first-line detection for overlay triggering.
**Scope**:
- IN: Pattern matching on file paths, import statements, and diff content for security-sensitive signals (auth, crypto, external integrations, data layer) and performance-sensitive signals (database access, loop structures, concurrency primitives, caching). Flags emitted in the same JSON output consumed by the review dispatch workflow.
- OUT: Overlay dispatch logic, reviewer agent definitions, deterministic scanning tool installation

## Done Definitions

- When this story is complete, the classifier emits security_overlay and performance_overlay boolean flags in its JSON output alongside the existing tier score and factor scores
- When this story is complete, security-sensitive file paths, import patterns, and diff content trigger security_overlay=true
- When this story is complete, performance-sensitive file paths, patterns, and diff content trigger performance_overlay=true
- When this story is complete, unit tests written and passing for all new classification logic

## Considerations

- [Testing] Internal tooling — unit tests within this story per TDD DoD

