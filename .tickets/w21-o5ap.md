---
id: w21-o5ap
status: open
deps: []
links: []
created: 2026-03-20T17:23:47Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-24kl
---
# As a developer, I have complete CLI documentation for all ticket commands


## Notes

**2026-03-20T17:25:03Z**

## Description
**What**: Complete CLI command reference for all ticket commands. CLAUDE.md updates. All documentation deferred from Epics 1-3.
**Why**: After cutover, agents need accurate documentation for the new system. This is the authoritative reference.
**Scope**:
- IN: CLI reference (init, create, show, list, transition, comment, link, unlink, deps, sync, archive, bridge-status, bridge-fsck, --format=llm), CLAUDE.md architecture section, quick reference table, rules, path references, all deferred Epics 1-3 documentation
- OUT: Reference update commit (w21-wbqz commits this work)

## Done Definitions
- CLI reference documents every ticket command with usage, options, and expected output ← Satisfies SC8
- CLAUDE.md architecture section describes the new event-sourced ticket system ← Satisfies SC4
- CLAUDE.md quick reference table uses ticket commands ← Satisfies SC4
- All documentation deferred from Epics 1-3 is included ← Satisfies SC4
- Documentation prepared in working tree for inclusion in S3's atomic commit

## Considerations
- [Maintainability] Documentation must cover every command from Epics 1-3 — audit against epic success criteria
- [Maintainability] Files are written to working tree but NOT committed independently — S3's atomic commit includes them

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. High confidence means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

<!-- note-id: d1nk5bk2 -->
<!-- timestamp: 2026-03-22T16:06:51Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

[Adversarial review] Additional consideration:
- [Reliability] S5 writes files to working tree without committing — fragile handoff to S4. If any intervening operation (git push, batch boundary) runs between S5 and S4, uncommitted files could be lost. S5 and S4 must execute in the same batch without intervening git operations.
