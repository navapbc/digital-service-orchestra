---
id: dso-l19q
status: open
deps: [dso-mjdp]
links: []
created: 2026-03-18T17:15:25Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-fel5
---
# As a DSO developer, shared hook support scripts are free of checkpoint-specific dead code


## Notes

**2026-03-18T17:17:11Z**

**What:** Remove checkpoint-specific dead code from 10 shared files: (1) `hook_checkpoint_rollback` function from `hooks/lib/pre-all-functions.sh` and its call from `hooks/dispatchers/pre-all.sh` (CRITICAL — must be updated atomically or every PreToolUse invocation fails); (2) `CHECKPOINT_LABEL`, `pre-checkpoint-base` block, and `.checkpoint-needs-review` exclusion from `hooks/compute-diff-hash.sh` (delete if all remaining logic is dead code); (3) `.checkpoint-needs-review` sentinel-handling from `hooks/record-review.sh` (`_RR_EXCLUDE`, `_RR_GREP_PATTERN`, sentinel-detection block); (4) checkpoint detection from `hooks/lib/session-misc-functions.sh`; (5) checkpoint detection block from `hooks/session-safety-check.sh`; (6) `.checkpoint-needs-review` from `scripts/capture-review-diff.sh` EXCLUDES; (7) `.checkpoint-needs-review` special case from `scripts/skip-review-check.sh`; (8) `pre-compact-checkpoint.sh` from `hooks/lib/review-gate-allowlist.conf`; (9) checkpoint exemption patterns from `hooks/lib/pre-bash-functions.sh`; (10) `checkpoint.marker_file` and `checkpoint.commit_label` from known-keys list in `scripts/validate-config.sh`.

**Why:** After S1 deregisters the hook, all checkpoint-related code in shared scripts is dead code. Leaving it creates confusion and maintenance burden.

**Scope:**
- IN: Epic crits 17-23; GAP-2 (session-safety-check.sh); GAP-3/CRITICAL (pre-all.sh dispatcher); GAP-4 (pre-bash-functions.sh exemptions); GAP-13 (validate-config.sh known keys)
- OUT: merge-to-main.sh/health-check.sh (S3), test file updates (S5)

**Done Definitions:**
- When complete, `hooks/dispatchers/pre-all.sh` contains no call to `hook_checkpoint_rollback` and `hooks/lib/pre-all-functions.sh` contains no `hook_checkpoint_rollback` function ← Epic crit 17 + GAP-3
- When complete, none of the listed scripts contain `CHECKPOINT_LABEL`, `checkpoint-needs-review` exclusions, or `checkpoint.marker_file` / `checkpoint.commit_label` keys ← Epic crits 18-23

**Considerations:**
- [Reliability] CRITICAL: `hooks/dispatchers/pre-all.sh` calls `hook_checkpoint_rollback()` at line 51 — remove this call in the same commit as the function removal or every PreToolUse invocation will fail at runtime
- [Maintainability] `hooks/compute-diff-hash.sh` may be entirely dead code after removals — determine whether to delete the file entirely
