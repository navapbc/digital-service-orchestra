---
id: dso-vfj0
status: open
deps: [dso-smgw, dso-quie]
links: []
created: 2026-03-21T08:34:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-njch
---
# Implement ticket-fsck.sh — non-destructive ticket system integrity validator

Implement plugins/dso/scripts/ticket-fsck.sh, a non-destructive integrity validator for the event-sourced ticket system.

File: plugins/dso/scripts/ticket-fsck.sh (create new)
Related: plugins/dso/scripts/ticket (edit — add fsck routing in Step 4 task)

Implementation:

ticket-fsck.sh runs five validation checks in order. It ONLY REPORTS issues — it does not modify ticket event files (exception: stale .git/index.lock removal is allowed since it is a lock file, not a ticket event).

Check 1 — JSON validity:
  Walk all .tickets-tracker/<ticket_id>/*.json files (excluding .cache.json).
  Attempt to parse each via python3 json.load. Report corrupt files.
  Output format per corrupt file: 'CORRUPT: <ticket_id>/<filename> — invalid JSON'

Check 2 — CREATE event presence:
  For each ticket directory, run ticket-reducer.py. If it returns None (no CREATE event) or status='error' or status='fsck_needed', flag the ticket.
  Output format: 'MISSING_CREATE: <ticket_id> — no CREATE event found'
  Output format: 'CORRUPT_CREATE: <ticket_id> — CREATE event present but missing required fields (ticket_type or title)'

Check 3 — Stale .git/index.lock cleanup:
  Check if .tickets-tracker/.git/index.lock exists.
  If exists: read PID from the file (if stored; otherwise use heuristic). Check if the PID is alive using 'kill -0 <PID> 2>/dev/null'.
  If PID is dead (or no PID stored and lock is older than 60 seconds): remove the lock file. Output: 'FIXED: removed stale .git/index.lock (PID <pid> is dead)'
  If PID is alive: Output: 'WARN: .git/index.lock held by live process PID <pid> — not removed'
  If no lock file: skip silently.
  NOTE: git does not always store PID in index.lock. Check mtime: if mtime > 60s ago and file exists with no live owner detectable, treat as stale and remove.

Check 4 — SNAPSHOT source_event_uuids consistency:
  For each SNAPSHOT event file: load source_event_uuids from data.source_event_uuids.
  Verify no source UUID corresponds to an event file that STILL EXISTS on disk in the same ticket directory.
  If any source UUID maps to a still-existing file: 'SNAPSHOT_INCONSISTENT: <ticket_id>/<snapshot_file> — source UUID <uuid> still exists as <filename>'
  Also verify no pre-snapshot events remain: any event file whose filename sorts BEFORE the SNAPSHOT filename and whose UUID is NOT in source_event_uuids is an orphan. Report: 'ORPHAN_EVENT: <ticket_id>/<filename> — pre-snapshot event not captured in source_event_uuids'

Check 5 — Summary:
  Print counts: 'fsck complete: <N> issues found' (or 'fsck complete: no issues found')
  Exit code: 0 if no issues, 1 if any issues found.

Implementation constraints:
- Use python3 for all JSON parsing (no bash string parsing of JSON)
- Non-destructive except for stale index.lock removal
- Must work when .tickets-tracker/ is not initialized (print error, exit 1 gracefully)

TDD Requirement: tests/scripts/test-ticket-fsck.sh must exist and be RED before implementing this. After implementation, all tests in test-ticket-fsck.sh must pass GREEN.

Acceptance Criteria:
- [ ] ticket-fsck.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-fsck.sh
- [ ] fsck exits 0 on a clean system with no issues
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-fsck.sh 2>&1 | grep -q 'no issues found'
- [ ] All tests in test-ticket-fsck.sh pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-fsck.sh
- [ ] fsck exits non-zero when issues found
  Verify: grep -q 'exit 1' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-fsck.sh
- [ ] JSON parsing uses python3 (not bash string parsing)
  Verify: grep -q 'python3' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-fsck.sh && ! grep -q 'grep.*{' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-fsck.sh
- [ ] ruff check passes on all .py files
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py

## GAP ANALYSIS AMENDMENT (dso-vfj0)

Error handling requirement for index.lock removal: if the stale lock file removal fails (e.g., permission denied, file already removed by concurrent process), fsck must NOT abort. It must catch the OSError, print a warning ('WARN: failed to remove stale .git/index.lock: <error>'), and continue with remaining checks. The exit code should still reflect the stale lock as an issue (exit 1), but the command must complete all checks regardless of the removal failure.

Add test coverage for this case in test-ticket-fsck.sh: test_fsck_handles_lock_removal_failure — create a lock file with restrictive permissions, run fsck, verify it continues and reports gracefully.

