---
id: w21-1plz
status: in_progress
deps: [w21-57k1]
links: []
created: 2026-03-21T00:52:13Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ablv
---
# Implement ticket init (orphan branch, worktree mount, .gitignore, env-id)


## Description

Implement the `ticket init` command as `plugins/dso/scripts/ticket-init.sh`.
Also create/update the `ticket` dispatcher at `plugins/dso/scripts/ticket` to route to subcommands.

### Implementation steps:
1. Create `plugins/dso/scripts/ticket-init.sh` — the init subcommand:
   a. Guard: if `.tickets-tracker/` already exists and is a valid worktree, exit 0 (idempotent)
   b. Add `.tickets-tracker` to `.git/info/exclude` (local, not committed to main branch)
   c. Check if `tickets` branch exists on origin; if yes, fetch and `git worktree add .tickets-tracker tickets`; if no, `git worktree add --orphan .tickets-tracker tickets`
   d. On first-time setup: `cd .tickets-tracker && git commit --allow-empty -m "chore: initialize ticket tracker"` (creates the branch root)
   e. Add `.gitignore` on the tickets branch: must contain `.env-id` and `.state-cache` entries; commit this file
   f. Generate UUID4 env-id: `python3 -c "import uuid; print(uuid.uuid4())"` → write to `.tickets-tracker/.env-id` (gitignored on tickets branch)
   g. Set `gc.auto = 0` in the tickets worktree's git config: `git -C .tickets-tracker config gc.auto 0`
   h. Print "Ticket system initialized." to stdout on success

2. Create `plugins/dso/scripts/ticket` dispatcher:
   - Routes `ticket init` → `ticket-init.sh`
   - Routes `ticket create` → `ticket-create.sh`
   - Routes `ticket show` → `ticket-show.sh`
   - Provides transparent auto-init (guard added in T11)
   - Must be executable (`chmod +x`)

### Constraints:
- All JSON construction via Python (json.dumps) — no bash heredoc for JSON
- All timestamps: UTC epoch seconds via `python3 -c "import time; print(int(time.time()))"`
- gc.auto=0 must be set in the worktree-level git config (`.tickets-tracker/.git/config`), NOT global

## TDD Requirement
GREEN: After implementation, `bash tests/scripts/test-ticket-init.sh` must return exit 0 (all 5 tests pass).
Depends on RED task w21-57k1 which defines the failing tests to make pass.

## Acceptance Criteria
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/run-all.sh`
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `plugins/dso/scripts/ticket-init.sh` exists and is executable
  Verify: `test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-init.sh`
- [ ] `plugins/dso/scripts/ticket` dispatcher exists and is executable
  Verify: `test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket`
- [ ] `ticket init` test suite passes (all 5 assertions green)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-init.sh`
- [ ] After `ticket init`, `.tickets-tracker/.env-id` contains a UUID4 string
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-init.sh 2>&1 | grep -c PASS | awk '{exit ($1 < 5)}'`
- [ ] `gc.auto` is set to 0 in the tickets worktree git config (not global)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-init.sh`

## Gap Analysis Amendments (from Step 6)

**AC Amendment — partial-init state (tickets branch exists but worktree absent):**
- [ ] `ticket init` handles re-mount case: if tickets branch exists on remote but .tickets-tracker/ is absent, `git worktree add .tickets-tracker tickets` re-mounts the existing branch (no duplicate commits)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-init.sh 2>&1 | grep -q 'test_ticket_init_remounts_existing_branch.*PASS'`
  Rationale: In a freshly cloned repo where the tickets branch was already pushed by another environment, `ticket init` should mount the existing branch (not create a new orphan). Without this check, running `ticket init` after a clone would fail with "branch already exists" or silently create a detached state. Add `test_ticket_init_remounts_existing_branch` to test-ticket-init.sh that simulates this scenario (create a bare remote, push a tickets branch to it, clone, then run ticket init in the clone).

## Notes

**2026-03-21T01:39:16Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T01:39:40Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T01:39:41Z**

CHECKPOINT 3/6: Tests written (pre-existing RED tests) ✓

**2026-03-21T01:40:28Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T01:49:50Z**

CHECKPOINT 5/6: Tests GREEN — 13 passed, 0 failed. Shellcheck clean. ✓

**2026-03-21T01:49:51Z**

CHECKPOINT 6/6: Done ✓
