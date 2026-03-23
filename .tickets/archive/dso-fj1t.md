---
id: dso-fj1t
status: closed
deps: []
links: []
created: 2026-03-22T03:27:22Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-d3gr
---
# As a developer, record-test-status.sh tolerates failures in RED-flagged test zones

## Description

**What**: Extend .test-index format to support an optional [first_red_test_name] marker on test file entries, and update record-test-status.sh to parse this marker and tolerate test failures at or after the marked function in the file.
**Why**: Enables TDD workflow where agents write RED tests before implementation without being blocked by the test gate when committing unrelated changes to the same source file.
**Scope**:
- IN: .test-index format extension with [marker] syntax, record-test-status.sh RED zone detection, per-test failure parsing for pytest and bash test files
- OUT: Changes to pre-commit-test-gate.sh (zero changes required), CI-side handling (status file already says passed), epic closure enforcement (separate story)

## Done Definitions

- When this story is complete, an agent can add [test_function_name] to a .test-index entry and record-test-status.sh tolerates failures from that function onward in the file while still blocking failures before it
  ← Satisfies: "An agent can commit a source file change when the associated test file contains RED tests, without being blocked by the test gate or CI"
- When this story is complete, GREEN tests defined before the RED marker still cause record-test-status.sh to exit non-zero when they fail
  ← Satisfies: "GREEN tests (defined before the RED marker in the test file) still block commits when they fail"
- When this story is complete, .test-index entries without a [marker] behave identically to current behavior
  ← Satisfies: backward compatibility
- When this story is complete, the RED zone detection works for both Python (def test_*) and bash (function/marker patterns) test files
  ← Satisfies: "The approach works for both Python (pytest) and bash test files"
- When this story is complete, unit tests are written and passing for all new or modified logic

## Considerations

- [Testing] Must parse per-test failure names from runner output — pytest -v and bash test output have different formats
- [Reliability] If the marker name doesn't match any function in the test file, the script should warn and fall back to blocking behavior (not silently tolerate everything)
- [Maintainability] .test-index parsing extension must be backward-compatible with existing entries

