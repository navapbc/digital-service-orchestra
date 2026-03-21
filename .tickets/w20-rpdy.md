---
id: w20-rpdy
status: open
deps: [w20-gclc]
links: []
created: 2026-03-21T16:24:17Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6k7v
---
# Implement _sync_events split-phase git sync in plugins/dso/scripts/tk

Add _sync_events() and cmd_sync_events() to plugins/dso/scripts/tk. TDD: T3 tests (w20-gclc) must be RED before starting. After implementation all T3 tests must be GREEN.

Phase 1 — Fetch (no flock):
  timeout 30 git -C "$tracker_dir" fetch origin tickets 2>&1 || { echo 'error: fetch timed out or failed'; return 1; }

Phase 2 — Acquire flock (same lock as write_commit_event in ticket-lib.sh):
  Reuse Python fcntl.flock inline subprocess pattern from ticket-lib.sh.
  Lock file: .tickets-tracker/.ticket-write.lock
  Budget: 30s timeout per attempt, max 2 retries (consistent with ticket-flock-contract.md)
  On lock exhaustion: return 1 with human-readable error

Phase 3 — Local merge while holding flock (bounded to <10s):
  Install ERR trap to release flock on any failure: trap '_sync_events_release_flock' ERR
  timeout 10 git -C "$tracker_dir" merge --ff-only origin/tickets 2>/dev/null ||
    timeout 10 git -C "$tracker_dir" merge origin/tickets 2>&1 ||
    { _sync_events_release_flock; return 1; }
  Note: event files are UUID-named so git conflicts should not occur (different filenames).
  If merge fails unexpectedly, release flock and return 1.

Phase 4 — Release flock (explicit, before push):
  _sync_events_release_flock

Phase 5 — Push (no flock, retry on non-fast-forward):
  local push_attempts=0 push_max=3
  while [[ $push_attempts -lt $push_max ]]; do
    push_attempts=$((push_attempts + 1))
    timeout 30 git -C "$tracker_dir" push origin tickets 2>&1 && break
    push_exit=$?
    if [[ $push_exit -eq 128 ]]; then
      # Non-fast-forward: re-fetch and retry full acquire+merge cycle
      timeout 30 git -C "$tracker_dir" fetch origin tickets 2>/dev/null || true
      _sync_events_acquire_and_merge || return 1
      continue
    fi
    return $push_exit
  done

Register sync-events in tk dispatch table.
_sync_events_release_flock: helper that closes the flock fd (Python subprocess).
Validate .tickets-tracker/ exists before running; exit with clear error if not initialized.

Depends on: w20-gclc (RED tests must exist and fail)


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] bash syntax check passes
  Verify: bash -n $(git rev-parse --show-toplevel)/plugins/dso/scripts/tk
- [ ] T3 tests all pass GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-tk-sync-events.sh
- [ ] sync-events command registered in tk dispatch
  Verify: grep -q 'sync-events\|sync_events' $(git rev-parse --show-toplevel)/plugins/dso/scripts/tk
- [ ] fetch uses transport-agnostic timeout wrapper
  Verify: grep -q 'timeout 30 git.*fetch' $(git rev-parse --show-toplevel)/plugins/dso/scripts/tk
- [ ] merge uses bounded timeout (flock held <10s)
  Verify: grep -q 'timeout 10 git.*merge' $(git rev-parse --show-toplevel)/plugins/dso/scripts/tk
- [ ] push uses transport-agnostic timeout wrapper
  Verify: grep -q 'timeout 30 git.*push' $(git rev-parse --show-toplevel)/plugins/dso/scripts/tk
- [ ] flock uses same lock file as write_commit_event
  Verify: grep -c '\.ticket-write\.lock' $(git rev-parse --show-toplevel)/plugins/dso/scripts/tk | awk '{exit ($1 < 1)}'

## GAP ANALYSIS AMENDMENTS

- [ ] _sync_events_acquire_and_merge helper is explicitly defined (not undefined reference)
  Verify: grep -q '_sync_events_acquire_and_merge\s*()\|function _sync_events_acquire_and_merge' $(git rev-parse --show-toplevel)/plugins/dso/scripts/tk
- [ ] cmd_sync_events validates origin remote is configured before fetching
  Verify: grep -q 'git.*remote\|ls-remote.*origin\|remote show origin' $(git rev-parse --show-toplevel)/plugins/dso/scripts/tk
