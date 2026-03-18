---
id: dso-0vyd
status: open
deps: [dso-wo1i, dso-0isl]
links: []
created: 2026-03-18T02:38:24Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-8qvu
---
# Update project docs to reflect check-skill-refs.sh, qualify-skill-refs.sh, and the qualified DSO skill namespace

## What
Update CLAUDE.md to document `check-skill-refs.sh` and `qualify-skill-refs.sh` in the Quick Reference table and architecture section. Ensure any new skill references added in this story use qualified `/dso:` form.

## Why
After the epic completes, future contributors need to be aware that all skill references must use the `/dso:` namespace and that a CI linter enforces it. Without CLAUDE.md updates, agents starting a new session won't know the scripts exist or what the qualification policy is.

## Scope
IN:
- CLAUDE.md: Quick Reference table (add check-skill-refs.sh row), architecture section (document qualification policy and the two new scripts)

OUT:
- Creating new documentation files — only updating existing CLAUDE.md
- Modifying any implementation — pure documentation update
- Re-qualifying existing CLAUDE.md references — already handled by dso-0isl

## Done Definitions
- When this story is complete, CLAUDE.md Quick Reference table includes entries for `check-skill-refs.sh` and `qualify-skill-refs.sh`
  <- Satisfies: "A first-time DSO contributor can identify skill ownership by reading the call site alone"
- When this story is complete, CLAUDE.md architecture section documents the qualification policy (all skill invocations must use `/dso:` prefix) and the role of both new scripts
  <- Satisfies: contributor discoverability criterion
- When this story is complete, all newly added skill references in CLAUDE.md use qualified `/dso:` form and `check-skill-refs.sh` exits 0
  <- Satisfies: no-regression finding from adversarial review (Story C must not undo Story B's qualification)

## Considerations
- [Compliance] All new prose added to CLAUDE.md that mentions DSO skill invocations must use the qualified form (e.g., `/dso:sprint` not `/sprint`) — `check-skill-refs.sh` will fail the CI gate otherwise
- Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting, structure, and conventions

## ACCEPTANCE CRITERIA
- Verify: `grep 'check-skill-refs' CLAUDE.md` — script mentioned in CLAUDE.md
- Verify: `grep 'qualify-skill-refs' CLAUDE.md` — script mentioned in CLAUDE.md
- Verify: `bash scripts/check-skill-refs.sh` exits 0 after all doc edits

## File Impact
### Files to modify
- `CLAUDE.md`

## Notes

<!-- note-id: bk11xsqb -->
<!-- timestamp: 2026-03-18T02:40:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.
