---
id: dso-8fc5
status: in_progress
deps: []
links: []
created: 2026-03-18T17:15:25Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-fel5
---
# As a DSO developer, all dedicated checkpoint test files are deleted


## Notes

**2026-03-18T17:17:11Z**

**What:** Delete 15 dedicated checkpoint test files: `tests/hooks/test-pre-compact-marker.sh`, `tests/hooks/test-pre-compact.sh`, `tests/hooks/test-pre-compact-checkpoint-base.sh`, `tests/hooks/test-pre-compact-checkpoint-skip.sh`, `tests/hooks/test-checkpoint-sentinel.sh`, `tests/hooks/test-checkpoint-rollback-integration.sh`, `tests/hooks/test-checkpoint-rollback.sh`, `tests/hooks/test-checkpoint-merge-gate-fallback.sh`, `tests/hooks/test-compute-diff-hash-checkpoint.sh`, `tests/hooks/test-pre-push-sentinel-check.sh`, `tests/plugin/test_analyze_precompact_telemetry.py`, `tests/plugin/test_precompact_telemetry.py`, `tests/plugin/test_analyze_precompact_telemetry.sh`, `tests/plugin/test_precompact_telemetry.sh`, `tests/skills/test-end-session-sentinel-write.sh`. Also delete `scripts/analyze-precompact-telemetry.sh`.

**Why:** All these files test checkpoint behavior that is being entirely removed. They have no value once the system is gone.

**Scope:**
- IN: Epic crits 3-13; GAP-7 (test-checkpoint-rollback.sh); GAP-1 follow-through (test-pre-push-sentinel-check.sh)
- OUT: Shared test file updates where checkpoint assertions appear alongside non-checkpoint tests (S5)

**Done Definitions:**
- When complete, none of the listed file paths exist ← Epic crits 3-13
- When complete, `bash tests/run-all.sh` does not error due to missing test files (the test runner is not referencing deleted files by name)

**Considerations:**
- [Testing] Confirm `tests/run-all.sh` does not glob or explicitly list deleted filenames — if it does, update the manifest as part of this story
