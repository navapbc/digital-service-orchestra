---
id: dso-ljbc
status: closed
deps: [dso-6b5d]
links: []
created: 2026-03-21T06:50:10Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-f8tg
---
# IMPL: Add content-hash caching to reduce_ticket() with atomic writes

Add compiled-state caching to ticket-reducer.py. The cache stores the output of reduce_ticket() keyed to a content hash of the ticket directory's file listing. Implements atomic cache writes and idempotent concurrent recompilation.

## TDD Requirement

This task makes the 3 RED tests from Task dso-6b5d pass (GREEN):
- test_cache_hit_returns_cached_state
- test_cache_miss_on_directory_listing_change
- test_cache_invalidated_on_file_deletion

Run the RED tests first to confirm they fail, then implement to make them pass.

## Implementation Details

### Cache Location

Store cache per ticket directory: <ticket_dir>/.cache.json

The cache file contains two keys:
- 'dir_hash': the content hash of the directory listing (see below)
- 'state': the compiled state dict

### Content Hash Computation

Hash the SORTED list of all *.json filenames in the ticket directory (not paths, just basenames). Do NOT hash mtimes. Use hashlib.sha256:

    import hashlib
    filenames = sorted(os.listdir(ticket_dir))  # all files, not just *.json, to detect .cache.json changes
    # Actually: only hash *.json event files (exclude .cache.json itself)
    event_files = sorted(f for f in os.listdir(ticket_dir) if f.endswith('.json') and f != '.cache.json')
    dir_hash = hashlib.sha256('|'.join(event_files).encode()).hexdigest()

### Cache Read (cache hit path)

At the start of reduce_ticket(), after computing dir_hash:
1. Check if <ticket_dir>/.cache.json exists
2. If exists, load it and compare stored 'dir_hash' with current dir_hash
3. If match: return the stored 'state' dict (cache hit — skip full compilation)
4. If mismatch: fall through to full compilation

### Cache Write (cache miss path)

After full compilation completes (state is computed):
1. Write state to a temp file: <ticket_dir>/.cache.tmp
2. Atomic rename: os.rename(.cache.tmp, .cache.json)
3. This ensures no reader ever sees a partial cache file

### Idempotent Concurrent Recompilation

Two processes computing from the same events produce identical output. The last atomic rename wins. Both results are correct — no corruption possible.

### Error Handling

- If .cache.json is corrupt (JSONDecodeError): treat as cache miss, recompute
- If .cache.tmp write fails (OSError): log warning to stderr, continue without caching
- If os.listdir() raises OSError (ticket dir removed mid-execution): treat as cache miss and fall through to the existing glob.glob() call (which will return empty list, resulting in None return — correct behavior)
- Cache errors must NEVER propagate to callers — reduce_ticket() always returns a valid result or None

GAP ANALYSIS AMENDMENT: The os.listdir() call for dir_hash computation must be wrapped in a try/except OSError to handle the race condition where the ticket directory is removed between the caller's existence check and the listdir() call. This is the same failure mode the existing glob.glob() already handles — the cache hash computation must be equally robust.

### Imports to Add

    import hashlib
    (json, os already imported)

## File Impact

- plugins/dso/scripts/ticket-reducer.py: Edit (add cache logic to reduce_ticket function, add hashlib import)

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` exits 0 (all tests pass including the 3 new cache tests)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/scripts/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/scripts/*.py
- [ ] test_cache_hit_returns_cached_state passes (GREEN)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py::test_cache_hit_returns_cached_state --tb=short -q
- [ ] test_cache_miss_on_directory_listing_change passes (GREEN)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py::test_cache_miss_on_directory_listing_change --tb=short -q
- [ ] test_cache_invalidated_on_file_deletion passes (GREEN)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py::test_cache_invalidated_on_file_deletion --tb=short -q
- [ ] Cache writes are atomic: .cache.json written via temp file + os.rename()
  Verify: grep -q 'os.rename' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-reducer.py
- [ ] Content hash uses sorted event file list (not mtime)
  Verify: grep -q 'hashlib' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-reducer.py
- [ ] Cache errors are non-fatal (OSError and JSONDecodeError caught)
  Verify: grep -qE 'JSONDecodeError|OSError' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-reducer.py
- [ ] All pre-existing 11 reducer tests still pass (no regression)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py --tb=short -q


## Notes

**2026-03-21T06:58:17Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T06:59:14Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T06:59:14Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T07:06:09Z**

CHECKPOINT 6/6: Done ✓ — Caching implemented. 14 tests GREEN.
