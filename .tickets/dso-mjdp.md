---
id: dso-mjdp
status: open
deps: []
links: []
created: 2026-03-18T17:15:24Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-fel5
jira_key: DIG-77
---
# As a DSO practitioner, context compaction no longer triggers checkpoint commits or review-gate checks


## Notes

**2026-03-18T17:17:11Z**

**What:** Delete `hooks/pre-compact-checkpoint.sh`, `hooks/post-compact-review-check.sh`, `hooks/pre-push-sentinel-check.sh`. Remove the `PreCompact` hook block from `.claude-plugin/plugin.json`. Remove `.checkpoint-pending-rollback` from `.gitignore`. Remove the `block-sentinel-push` pre-push hook entry from `.pre-commit-config.yaml`.

**Why:** This is the walking skeleton — after this story, triggering Claude Code context compaction is a no-op: no hook fires, no commit is made, no sentinel files are created. The pre-push sentinel is also removed since it only exists to block pushes containing `.checkpoint-needs-review` in HEAD.

**Scope:**
- IN: Criteria 1, 2, 14, 15 from epic; hooks/pre-push-sentinel-check.sh deletion (GAP-1); .pre-commit-config.yaml block-sentinel-push removal (GAP-5)
- OUT: Shared script cleanup (S2), merge/health scripts (S3), test deletions (S4), test updates (S5), docs (S6)

**Done Definitions:**
- When complete, `.claude-plugin/plugin.json` contains no `PreCompact` key ← Epic crit 14
- When complete, `hooks/pre-compact-checkpoint.sh` does not exist ← Epic crit 1
- When complete, `hooks/post-compact-review-check.sh` does not exist ← Epic crit 2
- When complete, `hooks/pre-push-sentinel-check.sh` does not exist
- When complete, `.gitignore` contains no entry for `.checkpoint-pending-rollback` ← Epic crit 15
- When complete, `.pre-commit-config.yaml` contains no `block-sentinel-push` hook entry

**Considerations:**
- [Reliability] Deregistering PreCompact in plugin.json is the single step that guarantees no hook fires — verify this is the only registration point (no settings.json override)

**2026-03-18T17:26:09Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
