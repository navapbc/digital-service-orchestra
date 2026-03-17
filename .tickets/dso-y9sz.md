---
id: dso-y9sz
status: open
deps: [dso-awoz, dso-0y9j, dso-r9fa]
links: []
created: 2026-03-17T19:51:56Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-42eg
---
# As a DSO contributor, I can verify shim reliability via automated cross-context smoke test


## Notes

<!-- note-id: 4nrn7pgr -->
<!-- timestamp: 2026-03-17T19:52:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## What
Create an automated cross-context smoke test that verifies the shim works reliably from all invocation contexts.

## Why
The shim must work from repo root, subdirectories, and worktrees. A smoke test proves this end-to-end and catches regressions.

## Scope
IN: Smoke test script at `tests/smoke-test-dso-shim.sh`; invokes shim from repo root, a subdirectory, and a worktree; asserts exit 0 each time; handles CI where worktrees may not pre-exist (creates a temporary worktree or skips that assertion gracefully with a warning)
OUT: Unit tests for individual shim functions (those live alongside S1's implementation)

## Done Definitions
- When this story is complete, `bash tests/smoke-test-dso-shim.sh` exits 0 when run from the repo root
  ← Satisfies: 'A cross-context smoke test...invokes the shim from the repo root, a subdirectory, and a worktree, asserting exit 0'
- When this story is complete, the test is included in the DSO plugin's test suite run
  ← Satisfies: 'A cross-context smoke test (included in the DSO plugin's test suite)'

## Considerations
- [Testing] CI may not have git worktree support or pre-existing worktrees — test must create its own temp worktree and clean it up, or detect the unavailability and skip with a non-zero-but-expected warning
