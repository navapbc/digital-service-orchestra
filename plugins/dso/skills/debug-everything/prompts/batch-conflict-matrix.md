## Batch Conflict Matrix (NxN Pairwise Overlap Detection)

After computing file impact for all candidates, build an **NxN pairwise overlap matrix**:
- For each pair of issues (i, j), check whether their `files_likely_modified` sets intersect
- **Write-write conflicts** (both issues modify the same file): defer the lower-priority
  issue to the next batch. The higher-priority issue (lower priority number, or earlier
  in dependency order) keeps its slot.
- **Read-read overlap** (`files_likely_read` intersections) is allowed — only write-write
  conflicts trigger deferral
- Log the conflict matrix to stderr for observability, using the same format as
  `$PLUGIN_SCRIPTS/ticket-next-batch.sh`:  # shim-exempt: internal orchestration script
  ```
  CONFLICT_MATRIX: <issue-A> x <issue-B> -> overlap on <file> (deferred: <issue-B>)
  ```

This deterministic, zero-LLM-cost approach replaces the previous sub-agent dispatch for
overlap checking. See `$PLUGIN_SCRIPTS/ticket-next-batch.sh` lines 545-583 for the  # shim-exempt: internal orchestration script
reference greedy selection algorithm with file-overlap detection.
