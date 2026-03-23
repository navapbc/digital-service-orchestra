---
id: w21-wbqz
status: closed
deps: [w21-25mq, w21-o5ap]
links: []
created: 2026-03-20T17:23:47Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-24kl
---
# As a developer, all tk references are atomically updated to the new ticket CLI in a single commit


## Notes

**2026-03-20T17:24:47Z**

## Description
**What**: Atomic reference update: enumerate all tk command patterns, replace across all skills/scripts/hooks/CLAUDE.md/docs, include S6's prepared documentation, syntax validate, commit as single atomic unit.
**Why**: The reference update is the point of no return for the active system. Must be atomic and verified before committing.
**Scope**:
- IN: Enumerated sed patterns (tk show → ticket show, tk create → ticket create, etc.), path updates (.tickets/ → .tickets-tracker/), post-update grep (no remaining tk refs), syntax validation (bash -n, py_compile), single atomic commit including S6 documentation, cutover script excluded from reference update
- OUT: Cleanup (w21-gy45)

## Done Definitions
- All tk references updated to ticket using enumerated command-specific patterns ← Satisfies SC4
- Post-update grep confirms no remaining tk references in in-scope files ← Satisfies SC4
- Syntax validation passes (bash -n on .sh, py_compile on .py) ← Satisfies SC4
- Documentation from w21-o5ap included in the atomic commit ← Satisfies SC4, SC8
- On failure: git checkout HEAD -- . restores all files ← Satisfies SC1
- Unit tests passing

## Considerations
- [Reliability] Enumerated patterns, not blanket s/tk/ticket/g — prevents corrupting 'toolkit', 'token', etc.
- [Reliability] Cutover script directory excluded from reference update (uses new commands from the start)
- [Maintainability] CLAUDE.md prose descriptions updated alongside command references

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. High confidence means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

<!-- note-id: ohmotare -->
<!-- timestamp: 2026-03-22T16:06:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

[Adversarial review] Additional done definitions:
- Enumerated patterns must include .tickets/ path references in review-gate-allowlist.conf and compute-diff-hash.sh (not just tk command references) — update to v3 storage paths or the review gate will block/miss v3 ticket writes
- .gitattributes merge driver entry and merge-ticket-index.py must be updated or removed — stale merge infrastructure causes worktree workflow failures

**2026-03-23T15:07:51Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
