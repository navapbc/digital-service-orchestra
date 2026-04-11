# Contract: Ticket Sync-Events Split-Phase Git Sync Protocol

- Status: accepted
- Scope: ticket-system-v3 (epic w21-6k7v)
- Date: 2026-03-21

## Purpose

This document defines the cross-story contract for `.claude/scripts/dso ticket sync` — the split-phase git sync
protocol for the tickets branch. It documents phase boundaries, lock scope, timeout budget, retry
behavior, and error paths. Downstream stories that archive tickets or compact event logs **must**
conform to this contract.

---

## Command Entry Point

**Command**: `.claude/scripts/dso ticket sync`

**Shell function**: `_sync_events` (defined in the sync implementation)

**Prerequisites** (validated by `cmd_sync_events` before calling `_sync_events`):

| Prerequisite | Check |
|---|---|
| `.tickets-tracker/` initialized | Directory must exist (`test -d .tickets-tracker`) |
| `origin` remote configured | `git remote show origin` must succeed inside `.tickets-tracker/` |
| `tickets` branch in remote | Required for `git fetch origin tickets` and `git push origin tickets` |

If `.tickets-tracker/` is absent, the command exits non-zero with:
```
error: ticket tracker not initialized (.tickets-tracker/ not found)
```

If `origin` is not configured:
```
error: origin remote not configured in <tracker_dir>
```

To satisfy these prerequisites, run `.claude/scripts/dso ticket init` to initialize the tracker store. See
`plugins/dso/scripts/ticket-init.sh`. # shim-exempt: internal implementation path reference

---

## Phases

`_sync_events` executes five sequential phases. The write lock (`.ticket-write.lock`) is held
**only during Phase 3** (local merge) — it is never held during network I/O.

### Phase 1 — Fetch

```bash
timeout 30 git -C "$tracker_dir" fetch origin tickets
```

- **Lock held**: no
- **Timeout**: 30 seconds (`timeout 30`)
- **On failure**: returns non-zero immediately; no lock acquired

The fetch runs without holding the write lock so that slow or stalled network operations do not
block concurrent ticket write operations.

### Phase 2 — Acquire flock

Lock acquisition is delegated to `_sync_events_acquire_and_merge`:

```python
fd = open(".ticket-write.lock", O_CREAT | O_RDWR)
deadline = time.monotonic() + 30   # 30s per attempt
while time.monotonic() < deadline:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break   # acquired
    except (IOError, OSError):
        time.sleep(0.1)   # poll at 100ms intervals
```

- **Lock file**: `.tickets-tracker/.ticket-write.lock`
- **Mechanism**: Python `fcntl.flock` — `LOCK_EX | LOCK_NB`, polled at 100 ms intervals
- **Timeout per attempt**: 30 seconds
- **Max retries**: 2 (the acquisition loop runs up to 2 times)
- **On exhaustion**: exits non-zero with:
  ```
  error: flock: could not acquire lock after 60s
  ```

See [ticket-flock-contract.md](ticket-flock-contract.md) for the full flock mechanism specification.

### Phase 3 — Local merge (flock held)

```bash
timeout 10 git -C "$tracker_dir" merge --ff-only origin/tickets \
  || timeout 10 git -C "$tracker_dir" merge origin/tickets
```

- **Lock held**: yes — acquired in Phase 2, held through end of Phase 3
- **Timeout**: 10 seconds (hard `timeout 10` per merge attempt)
- **Strategy**: fast-forward first; falls back to a standard merge on ff failure
- **Flock scope**: <10 seconds bounded — lock is never held across network operations
- **On merge failure**: lock is released immediately (`exec 9>&-`) and the function returns 1

The 10-second merge bound is intentionally short: while the write lock is held, concurrent
`ticket write` operations block. The <10s bound keeps the worst-case blocking duration
predictable.

### Phase 4 — Release flock

```bash
exec 9>&-
```

- **Lock released**: before push begins
- **Rationale**: push may take 30 seconds; holding the lock during push would block all
  concurrent write operations for the full push duration

`_sync_events_release_flock` is also registered as an ERR trap so the lock is released on
any unexpected error exit.

### Phase 5 — Push with retry

```bash
timeout 30 git -C "$tracker_dir" push origin tickets
```

- **Lock held**: no
- **Timeout per attempt**: 30 seconds
- **Max push attempts**: 3
- **Retry trigger**: exit code 128 (non-fast-forward rejection)

On exit 128, the full acquire+merge cycle (Phases 2–4) is re-executed before retrying the push.
This ensures the local branch is up to date before each push attempt.

| push exit code | Meaning | Action |
|---|---|---|
| 0 | Success | Done |
| 128 | Non-fast-forward | Re-fetch + re-merge + retry (up to 3 total attempts) |
| other | Unrecoverable push error | Return that exit code immediately |

---

## Timeout Budget

| Phase | Operation | Timeout | Lock held? |
|---|---|---|---|
| 1 — Fetch | `git fetch origin tickets` | 30s | No |
| 2 — Acquire flock | Python `fcntl.flock` poll loop | 30s × 2 retries = 60s max | Acquiring |
| 3 — Merge | `git merge` | 10s | Yes |
| 4 — Release | `exec 9>&-` | instantaneous | Released |
| 5 — Push | `git push origin tickets` | 30s × 3 attempts = 90s max | No |

**Worst-case total** (single attempt, no retries): 30s + 60s + 10s + 30s = **130 seconds**

**Typical case** (no contention, fast-forward): ~5s fetch + ~1s merge + ~5s push = **~11 seconds**

The worst-case total intentionally exceeds the ~73-second Claude tool-call ceiling because
`sync-events` is designed to be called from scripts (e.g., `merge-to-main.sh`) and cron jobs
rather than interactively from within a Claude tool call. For interactive use, callers should
set `timeout: 600000` on the enclosing Bash tool call.

---

## Flock Scope

The write lock is held **only during Phase 3** (local git merge):

```
fetch ──(no lock)──► acquire lock ──► merge ──► release lock ──(no lock)──► push
                     Phase 2          Phase 3    Phase 4                     Phase 5
```

This design minimizes contention: only the merge operation (which is local and fast, <10s) runs
under the lock. The slow network operations (fetch and push) run without the lock.

---

## Error Paths

| Failure point | Behavior |
|---|---|
| Phase 1 (fetch) fails | Return non-zero immediately; no lock acquired |
| Phase 2 (lock exhaustion after 2 retries) | Log error to stderr; return 1 |
| Phase 3 (merge fails) | Release lock immediately; return 1 |
| Phase 5 (push fails with non-128) | Return the push exit code immediately |
| Phase 5 (exit 128, all 3 attempts exhausted) | Return the last push exit code |
| Unexpected ERR trap | `_sync_events_release_flock` releases lock via `exec 9>&-` |

In all failure cases, no partial state is left on disk — either the push succeeded and the remote
is updated, or the remote is unchanged.

---

## Consumer Story Obligations

| Consumer story | Dependency |
|---|---|
| w21-6k7v (split-phase git sync) | Implements `_sync_events` per this contract |
| w21-6llo (archiving must sync before compacting) | Must call `.claude/scripts/dso ticket sync` before running compaction; compaction must not begin while a sync is in progress |
| w20-bkid (this document) | Documents the contract |

### w21-6llo (archive before compact)

The archiving pipeline must:

1. Call `.claude/scripts/dso ticket sync` to pull remote events before reading the event log
2. Complete `.claude/scripts/dso ticket sync` successfully (exit 0) before beginning compaction
3. Not interleave sync and compaction — the two operations must be strictly sequential

This ordering ensures that compaction reads the most recent event state and does not overwrite
events committed by other environments since the last local fetch.

---

## Prerequisites for `.claude/scripts/dso ticket sync`

Operators setting up a new environment must ensure:

1. **`origin` remote configured**: the `.tickets-tracker/` git worktree must have a remote named
   `origin` pointing to the shared repository.
   ```bash
   git -C .tickets-tracker remote add origin <url>
   ```

2. **`tickets` branch exists in remote**: `git fetch origin tickets` must succeed. If the branch
   does not exist, create it:
   ```bash
   git -C .tickets-tracker push origin tickets:tickets
   ```

3. **`.tickets-tracker/` initialized**: run `.claude/scripts/dso ticket init` from the repo root (see
   `plugins/dso/scripts/ticket-init.sh`). # shim-exempt: internal implementation path reference This creates the tracker store and sets `gc.auto=0`
   in the worktree's local git config.

These prerequisites are checked at command entry by `cmd_sync_events` and fail fast with
diagnostic messages if not satisfied.
