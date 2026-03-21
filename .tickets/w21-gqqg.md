---
id: w21-gqqg
status: open
deps: [w21-m4i9]
links: []
created: 2026-03-21T00:56:32Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ablv
---
# Contract: flock lock-file location and timeout budget documentation


## Description

Document the flock lock-file location and timeout budget as a cross-story contract that downstream stories (w21-q0nn compaction, w21-ay8w concurrency stress test) depend on.

**Location to create**: plugins/dso/docs/contracts/ticket-flock-contract.md

### Contract specification:
- **Lock file location**: `.tickets-tracker/.ticket-write.lock` (global per-worktree, one lock for all ticket write operations)
- **Lock scope**: global (not per-ticket); all write commands acquire the same lock to prevent index corruption
- **Flock timeout**: 30 seconds per attempt (matches Done Definition 14: max 30s per attempt)
- **Max retries**: 2 (total worst-case wait: 60 seconds — within 73s Claude timeout ceiling)
- **Error behavior**: If flock cannot be acquired after max retries, the command exits 1 with: `"Error: could not acquire ticket write lock after <N>s. Another ticket operation may be in progress."`
- **Lock release**: flock is released automatically when the subshell exits (no explicit unlock needed if using `flock -w 30 fd` pattern)
- **gc.auto=0**: Set in `.tickets-tracker/.git/config` (NOT global git config) — prevents garbage collection from holding the lock during Claude's ~73s timeout ceiling

### Why this matters for downstream stories:
- w21-q0nn (compaction): must hold flock for the entire compaction operation (read events + write snapshot + delete originals) — must use the same lock file
- w21-ay8w (concurrency stress): validates that 5 parallel sessions can complete 10 operations each without data loss — requires the flock contract to be specified before the test is written

## TDD Requirement
test-exempt: static assets only — no conditional logic, no executable code. This task creates a contract document only.
Exemption criterion: "static assets only — no executable assertion is possible."

## Acceptance Criteria
- [ ] Contract document exists at `plugins/dso/docs/contracts/ticket-flock-contract.md`
  Verify: `test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-flock-contract.md`
- [ ] Contract specifies the lock file path `.tickets-tracker/.ticket-write.lock`
  Verify: `grep -q '\.ticket-write\.lock' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-flock-contract.md`
- [ ] Contract specifies max flock timeout (30s per attempt, 2 retries)
  Verify: `grep -q '30' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-flock-contract.md`
- [ ] Contract specifies gc.auto=0 scope (worktree-level, not global)
  Verify: `grep -q 'gc.auto' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-flock-contract.md`
