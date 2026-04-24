# Contract: Ticket Flock Lock-File Location and Timeout Budget

- Status: accepted
- Scope: ticket-system-v3 (epic w21-ablv)
- Date: 2026-03-20

## Purpose

This document defines the cross-story contract for the flock-based write serialization layer used by all ticket write operations. Downstream stories that perform concurrent writes or compaction **must** conform to this contract.

| Consumer story | Dependency |
|----------------|-----------|
| w21-q0nn (compaction) | Must acquire the same lock file for the full compaction operation |
| w21-ay8w (concurrency stress) | Validates the timeout budget and lock exclusivity under 5 parallel sessions |
| w21-6k7v (sync-events) | Acquires `.ticket-write.lock` **only during the local git merge phase** (<10s); lock is released before push begins |

---

## Lock File Location

```
.tickets-tracker/.ticket-write.lock
```

- **Path**: `<repo-root>/.tickets-tracker/.ticket-write.lock`
- **Scope**: global per-worktree — one lock file covers **all** ticket write operations, regardless of which ticket is being written
- **Creation**: the file is created on first write via `os.O_CREAT | os.O_RDWR` (Python `os.open`); callers do not need to pre-create it
- **Persistence**: the file remains on disk after each operation (never deleted); its existence has no semantic meaning — only the flock state matters

This is intentionally a single global lock, not a per-ticket lock. A global lock prevents index corruption across concurrent writers operating on different tickets simultaneously.

---

## Timeout Budget

| Parameter | Value | Source |
|-----------|-------|--------|
| Flock timeout per attempt | 30 seconds | `flock_timeout=30` in `ticket-lib.sh` |
| Max retries | 2 | `max_retries=2` in `ticket-lib.sh` |
| Worst-case total wait | 60 seconds | `flock_timeout * max_retries` |

The 60-second worst-case total is intentionally within the ~73-second Claude tool-call timeout ceiling, leaving ~13 seconds of headroom for the rename + git operations that run while holding the lock.

---

## Locking Mechanism

### Current: Bash-native flock(1)

The lock is currently implemented using the **`flock(1)` CLI** (bash-native), introduced with the dispatcher shift from `python3` subprocesses to the sourced `ticket-lib-api.sh` library. This provides portable serialization on both macOS and Linux without Python startup overhead.

#### Acquisition loop (per attempt)

```bash
# Canonicalize the lock path to avoid cross-symlink flock mismatches
CANONICAL=$(cd "$(dirname "$lock_file")" && pwd -P)/$(basename "$lock_file")

attempt=0
while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))
    if flock -x -w 30 "$CANONICAL" bash -c '_perform_write "$@"' _ "$@"; then
        lock_acquired=true; break
    fi
    # exit non-zero on timeout → retry
done
```

- `flock -x` — exclusive lock (`LOCK_EX`)
- `flock -w 30` — 30-second blocking wait timeout
- 2-retry loop on timeout (same budget as historical path: 60s worst-case)
- **Cross-path canonicalization**: `CANONICAL=$(cd "$(dirname "$lock_file")" && pwd -P)/$(basename "$lock_file")` resolves symlinks before passing the path to `flock(1)`, ensuring that `.tickets-tracker/` symlinks (used in secondary worktrees) and their targets hold the same kernel lock.

#### Operations performed while holding the lock

1. Atomic rename of staging temp file to final event path (`mv -f staging_temp final_path` — same-filesystem mktemp guarantees atomicity)
2. `git -C <tracker_dir> add <ticket_id>/<final_filename>`
3. `git -C <tracker_dir> commit -q -m "ticket: <EVENT_TYPE> <ticket_id>"`

#### Lock release

The lock is released automatically when `flock`'s child process exits. No explicit `LOCK_UN` call is required — the OS releases the lock when the file descriptor held by the `flock(1)` wrapper exits.

---

### Historical (pre-bash-native): Python fcntl.flock

> **Note**: The following describes the locking mechanism used before the bash-native dispatcher was introduced. It is preserved here for reference and for downstream stories that were designed against the Python path (w21-q0nn, w21-ay8w, w21-6k7v). The semantics (timeout budget, retry count, operations under lock) are identical; only the implementation language changed.

The legacy lock used **Python `fcntl.flock`** (not the `flock(1)` CLI), invoked as a python3 subprocess per write operation.

```python
# Historical: Python fcntl.flock acquisition loop (per attempt)
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
deadline = time.monotonic() + timeout   # 30s
acquired = False
while time.monotonic() < deadline:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        acquired = True
        break
    except (IOError, OSError):
        time.sleep(0.1)   # poll at 100ms intervals
```

- Used `LOCK_EX | LOCK_NB` (non-blocking exclusive) polled at 100 ms intervals
- Deadline was wall-clock monotonic (not iteration count)
- Lock was released by closing the file descriptor (`os.close(fd)`) at subprocess exit — no explicit `flock(LOCK_UN)` required

---

## Retry Behavior

The bash wrapper retries the entire lock-acquire-and-commit block up to `max_retries` (2) times:

```bash
while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))
    flock -x -w 30 "$CANONICAL" bash -c '_perform_write "$@"' _ "$@" || flock_exit=$?
    if [ "$flock_exit" -eq 0 ]; then
        lock_acquired=true; break
    elif [ "$flock_exit" -eq 2 ]; then
        # git operation failed — do NOT retry
        echo "Error: git commit failed while holding lock" >&2; return 1
    elif [ "$flock_exit" -eq 3 ]; then
        # atomic rename failed — do NOT retry
        rm -f "$staging_temp"; echo "Error: atomic rename failed" >&2; return 1
    fi
    # exit code 1 (lock not acquired within timeout) → retry
done
```

| Exit code from Python | Meaning | Retry? |
|-----------------------|---------|--------|
| 0 | Lock acquired, rename + commit succeeded | — (success) |
| 1 | Lock not acquired within 30s timeout | Yes (up to max_retries) |
| 2 | git operation failed while holding lock | No |
| 3 | Atomic rename failed while holding lock | No |

---

## Error Behavior on Lock Exhaustion

If the lock cannot be acquired after all retries, the command exits 1 with:

```
flock: could not acquire lock after <N>s
```

Where `<N>` = `flock_timeout * max_retries` = 60 seconds.

The staging temp file is removed on lock exhaustion (`rm -f "$staging_temp"`). No partial state is left on disk.

---

## gc.auto=0 Scope

`gc.auto=0` is set **only** in the tickets worktree's local git config:

```
.tickets-tracker/.git/config
```

It is **never** set in the global git config (`~/.gitconfig`) or the host repository's config.

### Why this setting exists

Git's automatic garbage collection (`gc.auto`) can hold repository locks for seconds to minutes. During the ~73-second Claude tool-call timeout ceiling, a GC run triggered mid-operation could prevent the flock from completing within the 60-second budget.

Setting `gc.auto=0` disables automatic GC for the tickets worktree only, ensuring that GC never contends with ticket write locks. GC for the tickets branch can be run explicitly by an operator when needed.

### Where it is set

| Location | Set? | Method |
|----------|------|--------|
| `ticket-init.sh` | Yes | `git -C "$TRACKER_DIR" config gc.auto 0` (once, at init time) |
| `ticket-lib.sh` (`write_commit_event`) | Yes | `git -C "$tracker_dir" config gc.auto 0` (idempotent guard before each write) |
| Host repo config | Never | — |
| Global git config | Never | — |

The idempotent guard in `write_commit_event` ensures that even if the worktree is mounted on a machine where `.claude/scripts/dso ticket init` was not run directly, GC is still disabled before the first write.

---

## Downstream Story Obligations

### w21-q0nn (compaction)

The compaction operation must:

1. Acquire `.tickets-tracker/.ticket-write.lock` for the **entire** compaction sequence: read all events → write `SNAPSHOT` event → delete original event files
2. Use the same `flock_timeout=30` / `max_retries=2` budget
3. Not release the lock between the snapshot write and the deletion of original events — doing so would create a window where a concurrent writer could observe a half-compacted ticket directory

### w21-ay8w (concurrency stress test)

The stress test must validate:

1. 5 parallel sessions × 10 write operations each = 50 total writes complete without data loss
2. No two commits have identical filenames (timestamp + UUID uniqueness)
3. The final event log is linearizable (no gaps, no duplicates after reduction)
4. At least one session must have experienced lock contention (verified by timing or log inspection)

The stress test **must not** set a shorter timeout than `flock_timeout=30` — test harness timeouts must be set above 60 seconds to allow the full retry budget to exhaust before declaring failure.

### w21-6k7v (sync-events split-phase git sync)

The sync-events operation:

1. Acquires `.tickets-tracker/.ticket-write.lock` **only during the local git merge phase** (Phase 3 of the split-phase protocol)
2. Uses the same `flock_timeout=30` / `max_retries=2` budget as all other lock consumers
3. Releases the lock explicitly (Phase 4) **before** the push begins — the lock is never held during network I/O

This narrow lock scope (merge only, <10s) minimizes contention with concurrent `ticket write` operations. The full sync-events timeout budget and phase breakdown are documented in [ticket-sync-events-contract.md](ticket-sync-events-contract.md).
