---
id: dso-fel5
status: closed
deps: []
links: []
created: 2026-03-18T17:03:13Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Remove pre-compact checkpoint hook from DSO


## Notes

**2026-03-18T17:04:12Z**

## Context
DSO currently registers a `PreCompact` hook (`pre-compact-checkpoint.sh`) that auto-commits uncommitted work before Claude Code compacts its context window. The hook also writes a `.checkpoint-needs-review` sentinel that ties every compaction event to the two-layer code-review gate, forcing review clearance after each compaction. This creates disproportionate friction: practitioners are required to run code review on checkpoint commits that contain no deliberate code changes, and the rollback mechanism (`.checkpoint-pending-rollback`) adds a live working-tree file that must be cleaned up by other scripts. Engineering leadership has decided to remove the hook and all supporting infrastructure so context compaction no longer triggers git operations, review-gate checks, or sentinel-file management.

## Approach
Full surgical removal: delete all 16 checkpoint-dedicated files and strip checkpoint-related code from ~18 shared files. No replacement mechanism is introduced.

## Dependencies
None

**2026-03-18T17:04:42Z**

## Success Criteria

**Deleted files (16)**
1. hooks/pre-compact-checkpoint.sh is deleted.
2. hooks/post-compact-review-check.sh is deleted.
3. scripts/analyze-precompact-telemetry.sh is deleted.
4. tests/hooks/test-pre-compact-marker.sh is deleted.
5. tests/hooks/test-pre-compact.sh is deleted.
6. tests/hooks/test-pre-compact-checkpoint-base.sh is deleted.
7. tests/hooks/test-pre-compact-checkpoint-skip.sh is deleted.
8. tests/hooks/test-checkpoint-sentinel.sh is deleted.
9. tests/hooks/test-checkpoint-rollback-integration.sh is deleted.
10. tests/hooks/test-checkpoint-merge-gate-fallback.sh is deleted.
11. tests/hooks/test-compute-diff-hash-checkpoint.sh is deleted.
12. tests/plugin/test_analyze_precompact_telemetry.py, tests/plugin/test_precompact_telemetry.py, tests/plugin/test_analyze_precompact_telemetry.sh, and tests/plugin/test_precompact_telemetry.sh are deleted.
13. tests/skills/test-end-session-sentinel-write.sh is deleted.

**Hook registration and config**
14. .claude-plugin/plugin.json has the PreCompact hook block removed. After removal the file contains no PreCompact key.
15. .gitignore has the .checkpoint-pending-rollback entry removed.
16. docs/CONFIGURATION-REFERENCE.md has the checkpoint.marker_file key, checkpoint.commit_label key, and LOCKPICK_DISABLE_PRECOMPACT env-var entry removed.

**Hook support code**
17. hooks/lib/pre-all-functions.sh has the hook_checkpoint_rollback function and all supporting comments removed.
18. hooks/compute-diff-hash.sh has the CHECKPOINT_LABEL constant, pre-checkpoint-base detection block, and .checkpoint-needs-review exclusion removed. If all remaining logic is dead code, the file is deleted.
19. hooks/record-review.sh has the .checkpoint-needs-review sentinel-handling logic removed: the _RR_EXCLUDE exclusion pattern, the _RR_GREP_PATTERN clause, and the sentinel-detection block.
20. hooks/lib/session-misc-functions.sh has the pre-compaction-aware checkpoint-detection code removed.
21. scripts/capture-review-diff.sh has .checkpoint-needs-review removed from its EXCLUDES array.
22. scripts/skip-review-check.sh has the .checkpoint-needs-review special-case block removed.
23. hooks/lib/review-gate-allowlist.conf has any entry for pre-compact-checkpoint.sh removed, if one exists.

**Merge and health scripts**
24. scripts/merge-to-main.sh has _phase_checkpoint_verify and all its contents removed, removed from _ALL_PHASES, and its call in the main execution sequence removed. The phase is dropped entirely -- not renamed or absorbed.
25. scripts/health-check.sh has the cleanup logic for .checkpoint-pending-rollback and .checkpoint-needs-review removed.

**Skills, tests, and documentation**
26. skills/end-session/SKILL.md has Step 3.25 (writes .disable-precompact-checkpoint sentinel) removed. Surrounding step sequence re-numbered to remain contiguous.
27. skills/sprint/SKILL.md has the prose describing the PreCompact hook auto-commit behaviour removed.
28. tests/hooks/test-standalone-hooks-no-relative-paths.sh has pre-compact-checkpoint.sh removed from its registered-hooks array.
28a. tests/scripts/test-merge-to-main.sh has the tests that reference _phase_checkpoint_verify, assert checkpoint_verify runs before sync, or check .checkpoint-pending-rollback/.checkpoint-needs-review cleanup behaviour updated or removed.
28b. tests/scripts/test-health-check.sh has the tests that assert health-check removes .checkpoint-pending-rollback and .checkpoint-needs-review updated or removed.
28c. Any other test file not listed above that contains references to the behaviours being modified (hook_checkpoint_rollback, checkpoint sentinel files, checkpoint_verify phase assertions) is updated or removed.
29. docs/workflows/REVIEW-WORKFLOW.md has the pre-compaction checkpoint-detection note removed.
30. docs/WORKTREE-GUIDE.md has checkpoint_verify removed from every phase list or phase-sequence description.
31. docs/TEST-STATUS-CONVENTION.md has the line recognising pre-compact commits as a known commit type removed.
32. CLAUDE.md has three groups removed: (a) the no-verify exception naming PreCompact auto-save, (b) all .disable-precompact-checkpoint references and the /dso:end Step 3.25 instruction, and (c) checkpoint_verify from the merge-to-main.sh phase sequence.

**Verification**
33. grep -r over the repo (excluding .git/, .tickets/, and the epic ticket file) for each token returns zero matches: pre-compact-checkpoint, post-compact-review-check, hook_checkpoint_rollback, PreCompact, LOCKPICK_DISABLE_PRECOMPACT, disable-precompact, checkpoint-needs-review, checkpoint-pending-rollback, CHECKPOINT_LABEL, pre-compaction auto-save, checkpoint_verify.
34. bash tests/run-all.sh passes with exit 0.
35. A practitioner who triggers Claude Code context compaction after this epic is merged experiences no review-gate prompt and finds no new git commit, no .checkpoint-needs-review file, and no .checkpoint-pending-rollback file in their working tree.
