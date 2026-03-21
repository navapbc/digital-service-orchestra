---
id: w22-tpzd
status: open
deps: []
links: []
created: 2026-03-21T04:43:17Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w22-338o
---
# As a host project developer, my non-Python source changes are caught by the test gate via fuzzy matching

## Description

**What**: Replace the Python-only test association logic in pre-commit-test-gate.sh with alphanum-normalized fuzzy matching that works across all tech stacks (bash, Go, TypeScript, etc.)
**Why**: The test gate currently skips all non-.py files, allowing untested code changes to be committed without any gate enforcement — defeating the gate's purpose for multi-stack projects
**Scope**:
- IN: Rewrite _has_associated_test() to use alphanum normalization + substring matching; extract fuzzy match logic into a shared library function in hooks/lib/ so both the gate and scanner can call it; update the test-file skip filter to handle Go (_test.go), Jest (.test.ts/.spec.ts), and bash (test-) conventions (not just Python test_ prefix); update record-test-status.sh to use the shared fuzzy match function (its lines 83-117 have an independent copy that would diverge); add test_gate.test_dirs config key to dso-config.conf (default: tests/) and ensure both gate and recorder consume it; write test cases covering Python, bash, Go, and TypeScript naming conventions; write a benchmark test (20 files, <10s); write a dogfooding test reproducing the bump-version.sh gap
- OUT: .test-index support (Story 2); /dev-onboarding scanner (Story 3)

## Done Definitions

- When this story is complete, staging a bash script (e.g., bump-version.sh) that has an associated test file (test-bump-version.sh) triggers the test gate — the commit is blocked if those tests haven't been recorded as passing
  ← Satisfies: "The test gate uses alphanum-normalized fuzzy matching"
- When this story is complete, staging source files of any extension (.sh, .go, .ts, .py) with fuzzy-matched test files triggers the gate, not just .py files
  ← Satisfies: "The test gate uses alphanum-normalized fuzzy matching"
- When this story is complete, the gate searches directories configured via test_gate.test_dirs in dso-config.conf, defaulting to tests/
  ← Satisfies: "test directories are configurable via dso-config.conf"
- When this story is complete, a benchmark test confirms the gate processes 20 staged files with associated tests within 10 seconds
  ← Satisfies: "The test gate completes within the existing pre-commit timeout"
- When this story is complete, a test case reproduces the original bump-version.sh gap and verifies it is now caught
  ← Satisfies: "staging bump-version.sh triggers the test gate to require test-bump-version.sh"
- When this story is complete, unit tests are written and passing for all new or modified logic

## Considerations

- [Performance] Fuzzy match scans test directories with find — benchmark SC6 (20 files, <10s) must be validated
- [Testing] Normalization edge cases across naming conventions (Go _test.go suffix, Jest .test.ts suffix, bash test- prefix) — need test cases covering each convention
- [Maintainability] The test-file skip filter (line 87: test_* prefix check) must be updated to handle Go/Jest/bash conventions — otherwise test files trigger the gate on themselves creating circular requirements
- [Maintainability] record-test-status.sh has duplicated association logic (lines 83-117) that must use the same shared function — otherwise the recorder can't discover tests the gate requires, permanently blocking developers
- [Maintainability] Extract fuzzy match into hooks/lib/ as a shared function — the /dev-onboarding scanner (Story 3) needs to call it from a different context

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.

## Notes

**2026-03-21T16:21:29Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
