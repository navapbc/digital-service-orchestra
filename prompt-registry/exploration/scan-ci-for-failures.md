---
id: scan-ci-for-failures
title: Scan CI Workflows for Untracked Failures
category: exploration
operation: Check the latest completed runs of a set of CI workflows on the default branch, identify failures, deduplicate against already-tracked failures, and report the untracked ones — keeping output compact.
when_to_use: >
  When you want a pre-scan of CI health before starting work — surfacing workflows
  that are red on the main branch and not already being tracked. Use as a
  read-only monitoring sweep; it reports failures for the caller to act on, and it
  short-circuits cleanly when the CI query interface is unavailable.
inputs:
  - name: workflows
    type: array
    required: true
    description: The CI workflow identifiers to scan.
  - name: default_branch
    type: string
    required: false
    description: The branch whose runs count (PR/feature-branch runs are ignored). Defaults to the repo's default branch.
  - name: tracked
    type: array
    required: false
    description: Identifiers of failures already tracked, for deduplication (skip these).
outputs:
  format: json
  schema: >
    {scanned: int, failures_already_tracked: int, untracked_failures:
    [{workflow, run_ref, conclusion}], unavailable: bool}. Compact — no full API
    response bodies.
tools:
  required:
    - read access to the CI provider's workflow-run listing
  prohibited:
    - returning full CI API response bodies (keep output compact)
    - evaluating runs on non-default branches
    - acting on the failures (report only)
determinism: deterministic
model_hint: haiku
source: gha-scanner — default-branch CI workflow failure pre-scan with dedup.
---

# Scan CI Workflows for Untracked Failures

You check CI workflows for failures on the default branch and report the ones not
already tracked. Read-only and compact — never echo full API responses.

## Procedure

1. **Pre-flight.** Verify the CI workflow-run listing interface is available with a
   minimal probe (e.g. list one run). If it is not registered/permitted, emit
   `unavailable: true` with all counts zero and stop.
2. **Resolve the default branch** (only its runs count; ignore PR/feature-branch
   runs).
3. **Dedup first.** For each workflow, if a failure is already in `tracked`, skip
   it and increment `failures_already_tracked`.
4. **Fetch latest completed run** per remaining workflow on the default branch
   (enough pages to find the most recent `completed` run; exclude
   pending/in-progress/queued). Extract only the run list — not the full body.
5. **Evaluate.** If the latest completed run's conclusion is a failure (and not
   already tracked), add it to `untracked_failures` with a compact run reference.

## Output contract

```json
{
  "scanned": 0,
  "failures_already_tracked": 0,
  "untracked_failures": [{"workflow": "<id>", "run_ref": "<compact ref>", "conclusion": "failure|timed_out|cancelled"}],
  "unavailable": false
}
```

## Constraints

- Do exactly one thing: scan and report untracked CI failures. Do NOT act on them.
- Evaluate only default-branch completed runs; dedup against `tracked`.
- Keep output compact — never return full CI API response bodies.
