---
id: dso-1xw7
status: closed
deps: []
links: []
created: 2026-03-19T23:52:13Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-d72c
---
# Fix: fix-cascade-recovery skill missing read-config integration — eval fails


## Notes

<!-- note-id: gwxf5l3n -->
<!-- timestamp: 2026-03-19T23:52:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Cluster 3: fix-cascade-recovery skill missing read-config integration.

Root cause: The eval 'fix-cascade-recovery-skill-reads-config' checks for the pattern 'read-config' in plugins/dso/skills/fix-cascade-recovery/SKILL.md. The pattern is not found — the skill does not reference read-config.sh for config-driven behavior, unlike other skills which use it for config resolution.

Failing eval:
- fix-cascade-recovery-skill-reads-config: file_contains pattern 'read-config' not found in SKILL.md

Fix: Add appropriate read-config.sh reference in SKILL.md to enable config-driven behavior, or update the eval if the skill genuinely does not need config-driven behavior.

SAFEGUARDED: fix requires editing protected file(s): plugins/dso/skills/fix-cascade-recovery/SKILL.md

<!-- note-id: x7iuclub -->
<!-- timestamp: 2026-03-20T00:05:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

SAFEGUARD APPROVED: user approved editing plugins/dso/skills/fix-cascade-recovery/SKILL.md. Proposed fix: Replace hardcoded make test with config-driven TEST_CMD via read-config.sh

<!-- note-id: zysi4ypj -->
<!-- timestamp: 2026-03-20T00:08:37Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fix applied: Added Config Resolution section to SKILL.md with read-config.sh integration (matching pattern from fix-bug, sprint, and other skills). Also replaced hardcoded 'cd $(git rev-parse --show-toplevel)/app && make test' with 'cd $(git rev-parse --show-toplevel) && $TEST_CMD' in Step 1. Eval fix-cascade-recovery-skill-reads-config now passes (file_contains 'read-config' confirmed).

<!-- note-id: s4v0upc2 -->
<!-- timestamp: 2026-03-20T00:11:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT: Fix implemented. SKILL.md updated with read-config.sh integration (Config Resolution section added + TEST_CMD replacing hardcoded make test). Eval fix-cascade-recovery-skill-reads-config now passes. Files staged: plugins/dso/skills/fix-cascade-recovery/SKILL.md, .tickets/dso-1xw7.md. DIFF_HASH=1f03c1c3773d7d111efd50d33ccad23a72a1cb09abf396d37231c6893195f050 (captures full working tree including other agents changes). Awaiting orchestrator to run REVIEW-WORKFLOW.md (sub-agent Task tool not available in this sub-agent context).

<!-- note-id: zsspvw2e -->
<!-- timestamp: 2026-03-20T00:32:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: added read-config.sh integration to fix-cascade-recovery/SKILL.md

<!-- note-id: 3tfu55lt -->
<!-- timestamp: 2026-03-20T00:32:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: added read-config integration in fix-cascade-recovery/SKILL.md (commit 13bf60c)
