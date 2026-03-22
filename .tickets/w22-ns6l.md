---
id: w22-ns6l
status: open
deps: []
links: []
created: 2026-03-21T04:50:56Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# Project Health Restoration


## Notes

**2026-03-21T04:51:04Z**


## Context
During a /dso:debug-everything session on 2026-03-20, the DSO project was found to have 6 CI failures (all cascade-circuit-breaker Linux incompatibility), 1 flaky test (test-discover-agents.sh), and 6 open infrastructure bugs spanning the review gate, merge workflow, test timeout, and validation sub-agent behavior. These issues collectively block reliable CI and developer confidence. This epic tracks all discovered issues through to resolution so the project returns to a green, healthy baseline.

## Success Criteria
- CI passes cleanly on Linux (w21-qsu5 resolved — 0 cascade-circuit-breaker failures)
- test-discover-agents.sh no longer flakes in full suite runs (w22-1jqy resolved or confirmed isolated)
- Lock-acquire grep pattern matches synced ticket format in worktrees (dso-6q4p resolved)
- Merge commits from main into worktree pass the pre-commit review gate (w21-0oc6 resolved)
- End-session merge performs diff comparison before accepting worktree ticket changes (w21-0pxe resolved)
- Test suite completes within Claude Code tool timeout bounds (w21-2dby resolved)
- Pre-commit review gate permits non-allowlisted files in merge commits from incoming branch (dso-k7fe resolved)
- Local validation sub-agent does not redundantly check CI status (w21-jb9k resolved)

## Dependencies
None (this epic tracks pre-existing bugs; no sequencing dependencies between bugs)

## Approach
Tracking epic — each child bug is fixed independently. Fix order prioritized by tier: w21-qsu5 (CI/Tier 6) first, then Tier 7 bugs by priority.


**2026-03-21T05:14:11Z**

BATCH 1 | Tier 6
Issues: w21-qsu5 (closed)
Agent types: general-purpose (w21-qsu5)
Model tier: opus
Critic review: PASS
Outcome: 1 fixed, 0 failed, 0 reverted
Remaining in tier: 0

**2026-03-21T16:07:59Z**

BATCH 2 | Tier 7
Issues: w21-0oc6 (closed), dso-k7fe (closed), w21-0pxe (closed), w21-2dby (closed), dso-6q4p (closed), w21-jb9k (closed)
Agent types: general-purpose (all)
Model tier: opus (w21-0oc6+dso-k7fe), sonnet (others)
Critic review: skipped (post-batch validation passed)
Outcome: 6 fixed, 0 failed, 0 reverted
Remaining in tier: 1 (w22-1jqy)

**2026-03-22T15:51:56Z**

BATCH 1 | Tier 7
Issues: dso-u5lt (fixed), w21-9tc4 (fixed), dso-2dxt (fixed), w21-1pyo (escalated), w21-bksy (fixed)
Agent types: general-purpose (all)
Model tier: sonnet
Critic review: skipped (Tier 7 code bugs)
Outcome: 4 fixed, 1 escalated, 0 reverted
New bugs found: w22-w5wt (anti-pattern in REVIEW-WORKFLOW.md)
Remaining in tier: 14

**2026-03-22T16:05:29Z**

BATCH 2 | Tier 7
Issues: dso-jwan (fixed), w21-4jzh (already fixed), w21-fzzu (false positive), dso-gxct (fixed), dso-0u2q (fixed)
Agent types: general-purpose (all)
Model tier: sonnet
Outcome: 3 fixed, 2 closed (already fixed/false positive)
Remaining open bugs: ~12
