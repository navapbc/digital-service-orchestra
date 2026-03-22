---
id: dso-6r3o
status: in_progress
deps: []
links: []
created: 2026-03-22T19:16:51Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-uu13
---
# As a developer, the CI auto-ticket-creation pattern is fully removed

## Description

**What**: Remove the CI workflow job, scripts, test files, and example config related to automatic ticket creation on CI failure.
**Why**: CI doesn't reliably have access to tk (plugin dependency), and failures are already caught by ci-status.sh --wait. The auto-created tickets are noise requiring a dedicated cleanup script.
**Scope**:
- IN: Delete ci-create-failure-bug.sh, bulk-delete-stale-tickets.sh, tests/scripts/test-bulk-delete-stale-tickets.sh; remove create-failure-bug job from .github/workflows/ci.yml and examples/ci.example.yml
- OUT: Advisory hooks (check-validation-failures.sh, commit-failure-tracker.sh) — these inform but don't auto-create tickets

## Done Definitions

- When this story is complete, the create-failure-bug job no longer exists in .github/workflows/ci.yml
  ← Satisfies: "The create-failure-bug job no longer exists in .github/workflows/ci.yml"
- When this story is complete, ci-create-failure-bug.sh is deleted from the repository
  ← Satisfies: "The ci-create-failure-bug.sh script is deleted"
- When this story is complete, bulk-delete-stale-tickets.sh and its test file are deleted from the repository
  ← Satisfies: "The bulk-delete-stale-tickets.sh cleanup script is deleted"
- When this story is complete, the example CI workflow no longer includes the create-failure-bug job
  ← Satisfies: "The example CI workflow (examples/ci.example.yml) no longer includes the create-failure-bug job"
- When this story is complete, existing CI failure detection (ci-status.sh --wait) continues to work unchanged
  ← Satisfies: "Existing CI failure detection (ci-status.sh --wait) continues to work unchanged"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Testing] Test file tests/scripts/test-bulk-delete-stale-tickets.sh must be deleted alongside the script
- [Reliability] Confirmed no other scripts invoke ci-create-failure-bug.sh or bulk-delete-stale-tickets.sh

