---
id: w20-bkid
status: closed
deps: [w20-rpdy]
links: []
created: 2026-03-21T16:25:01Z
type: task
priority: 3
assignee: Joe Oakhart
parent: w21-6k7v
---
# Document split-phase git sync pattern in architecture docs

Create/update documentation for the split-phase sync pattern.

TDD exemption: static assets only — Markdown documentation with no executable assertions possible. Citing criterion 3: the task modifies only static assets (Markdown documentation, static config files) where no executable assertion is possible.

1. Create plugins/dso/docs/contracts/ticket-sync-events-contract.md:
   - Document _sync_events phases (fetch, acquire-flock, merge, release-flock, push)
   - Document flock scope (held only during merge phase, <10s bounded)
   - Document timeout budget (30s fetch, 10s merge, 30s push = 70s worst case for one attempt)
   - Document retry behavior (push retries up to 3x on exit 128)
   - Document error paths (flock released on merge failure)
   - Document consumer story: w21-6llo (archiving must sync before compacting)

2. Update plugins/dso/docs/contracts/ticket-flock-contract.md:
   - Add sync-events to the Downstream Story Obligations table (w21-6k7v)
   - Document: sync-events acquires .ticket-write.lock only during git merge phase

3. Document in plugins/dso/docs/INSTALL.md (or equivalent) that tk sync-events requires:
   - A git remote named origin
   - A branch named tickets in the remote
   - .tickets-tracker/ must be initialized (ticket init)

Style: Follow .claude/docs/DOCUMENTATION-GUIDE.md conventions.

Depends on: w20-rpdy (implementation shapes the documentation)


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Sync-events contract document created
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-sync-events-contract.md
- [ ] Sync-events contract documents all 5 phases
  Verify: grep -c 'fetch\|merge\|push\|flock\|release' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-sync-events-contract.md | awk '{exit ($1 < 3)}'
- [ ] ticket-flock-contract.md updated with sync-events entry
  Verify: grep -q 'sync-events\|w21-6k7v' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-flock-contract.md
