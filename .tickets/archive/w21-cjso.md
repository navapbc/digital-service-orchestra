---
id: w21-cjso
status: closed
deps: [w21-q6nv, w21-vz2h]
links: []
created: 2026-03-21T07:11:45Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-q0nn
---
# IMPL: Create ticket-compact.sh compaction script with flock, SNAPSHOT write, and specific-file deletion

Implement plugins/dso/scripts/ticket-compact.sh that compacts a ticket's event history into a single SNAPSHOT event when it exceeds the configured threshold.

## TDD Requirement
Depends on: RED tests for compaction (w21-q6nv) AND reducer SNAPSHOT impl (w21-vz2h).
After implementation, confirm GREEN:
  cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh
Expected: all compaction tests pass.

## Implementation Steps

File: plugins/dso/scripts/ticket-compact.sh

### Script Header and Arguments
```bash
#!/usr/bin/env bash
# ticket-compact.sh: compact a ticket's event history into a SNAPSHOT event
# Usage: ticket-compact.sh <ticket_id> [--threshold=N]
# Default threshold: COMPACT_THRESHOLD env var or 10
```

### Step 1: Validate arguments and initialization
- Require ticket_id argument
- Source ticket-lib.sh for write_commit_event and TRACKER_DIR
- Validate ticket dir exists at TRACKER_DIR/<ticket_id>

### Step 2: List and count event files (specific files only, captured before flock)
```bash
# Read event files BEFORE acquiring flock
# Sort lexicographically (= chronological by filename convention)
mapfile -t event_files < <(find "$ticket_dir" -maxdepth 1 -name '*.json' ! -name '.cache.json' ! -name '.*' | sort)
event_count=${#event_files[@]}
```

### Step 3: Threshold check
- If event_count <= threshold: echo 'below threshold — skipping'; exit 0

### Step 4: Compile current state via reducer
```bash
compiled_state_json=$(python3 "$SCRIPT_DIR/ticket-reducer.py" "$ticket_dir")
```

### Step 5: Acquire flock for entire compaction operation
- Use fcntl.flock via python3 (same pattern as write_commit_event in ticket-lib.sh)
- Hold flock while: write SNAPSHOT + git add/commit + delete original files + git add deletions + git commit
- flock timeout: 30s with max 2 retries (consistent with ticket-lib.sh)

### Step 6: Inside flock — generate SNAPSHOT event JSON via python3
```python
# Generate SNAPSHOT event with:
# - event_type: 'SNAPSHOT'
# - uuid: new uuid4
# - timestamp: int(time.time())
# - env_id: from compiled_state or from TRACKER_DIR/.env-id
# - author: from git config user.name
# - data.compiled_state: the compiled state dict
# - data.source_event_uuids: list of uuid field from each of the event_files captured in Step 2
```

### Step 7: Inside flock — write and commit SNAPSHOT event
- Use write_commit_event() from ticket-lib.sh (which handles atomic rename + git add + git commit)
- IMPORTANT: write_commit_event holds its own flock internally. To avoid deadlock, the outer flock in ticket-compact.sh and the inner flock in write_commit_event must use the same lock file OR ticket-compact.sh must inline the git operations rather than calling write_commit_event.
- IMPLEMENTATION CHOICE: Inline the git operations inside the outer flock (do not call write_commit_event). The inner flock in write_commit_event would deadlock on the outer flock already held.
- After SNAPSHOT is committed: delete the specific event_files captured in Step 2 (NOT a glob delete — only files in the `event_files` array)
- git add the deletions + git commit 'ticket: COMPACT <ticket_id>'

### Step 8: Release flock; cleanup temp files

## Key Invariants
- Only files captured in Step 2 (before flock) are deleted — events written during compaction (not in source_event_uuids) survive
- All JSON construction via python3 json.dumps — no bash string interpolation
- Atomic temp-file-then-rename for SNAPSHOT event file (before git add)
- flock timeout: 30s/attempt, max 2 retries (60s total)
- gc.auto=0 on tickets worktree (already set by ticket-lib.sh write_commit_event; idempotent guard here too)

## File to Create
plugins/dso/scripts/ticket-compact.sh

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ticket-compact.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-compact.sh
- [ ] All 7 compaction tests pass GREEN
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh 2>&1 | grep -v FAIL
- [ ] Compaction uses specific-file deletion (not glob), verified by source_event_uuids
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh 2>&1 | grep 'source_event_uuids.*PASS'
- [ ] SNAPSHOT event file parses as valid JSON with all required fields
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh 2>&1 | grep 'valid.*JSON.*PASS'
- [ ] Git operations are inlined inside the outer flock (write_commit_event NOT called from compact.sh) — no nested flock deadlock
  Verify: grep -v 'write_commit_event' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-compact.sh | grep -c 'fcntl.flock\|LOCK_EX' | awk '{exit ($1 < 1)}'
- [ ] compact.sh exits non-zero with a clear error message when ticket state cannot be compiled (corrupt or ghost ticket)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh 2>&1 | grep 'corrupt_ticket.*PASS'


## Notes

**2026-03-21T07:52:27Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T07:52:49Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T07:52:49Z**

CHECKPOINT 3/6: Tests written (pre-existing) ✓

**2026-03-21T08:05:59Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T08:06:34Z**

CHECKPOINT 5/6: All tests GREEN, shellcheck clean, corrupt handling verified ✓

**2026-03-21T08:06:38Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T08:21:02Z**

CHECKPOINT 6/6: Done ✓ — ticket-compact.sh. Tests: 10 passed, 0 failed.
