---
id: dso-jbcp
status: open
deps: []
links: []
created: 2026-03-18T17:15:25Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-fel5
---
# As a DSO developer, documentation and skills no longer reference the checkpoint system


## Notes

**2026-03-18T17:17:11Z**

**What:** Remove all checkpoint references from documentation and skills: (1) `checkpoint.marker_file`, `checkpoint.commit_label`, `LOCKPICK_DISABLE_PRECOMPACT` entries from `docs/CONFIGURATION-REFERENCE.md`; (2) Step 3.25 from `skills/end-session/SKILL.md` (re-number remaining steps); (3) PreCompact hook auto-commit prose from `skills/sprint/SKILL.md`; (4) pre-compaction checkpoint-detection note from `docs/workflows/REVIEW-WORKFLOW.md`; (5) `checkpoint_verify` from `docs/WORKTREE-GUIDE.md`; (6) pre-compact commit type line from `docs/TEST-STATUS-CONVENTION.md`; (7) three reference groups from `CLAUDE.md` (the no-verify exception naming PreCompact auto-save, all .disable-precompact-checkpoint references + Step 3.25 instruction, checkpoint_verify from merge phase sequence); (8) checkpoint recovery block and .checkpoint-needs-review note from `docs/workflows/COMMIT-WORKFLOW.md`; (9) block-sentinel-push entry from `examples/pre-commit-config.example.yaml`.

**Why:** Documentation referencing a removed system misleads future developers and agents about current behavior.

**Scope:**
- IN: Epic crits 16, 26-32; GAP-6 (COMMIT-WORKFLOW.md); GAP-5 (examples/pre-commit-config.example.yaml)
- OUT: Code-level changes (S1-S3); test file changes (S4-S5)

**Done Definitions:**
- When complete, none of the listed documentation files reference `checkpoint.marker_file`, `checkpoint.commit_label`, `LOCKPICK_DISABLE_PRECOMPACT`, `checkpoint_verify`, `.disable-precompact-checkpoint`, or `pre-compaction auto-save` ← Epic crits 16, 26-32
