---
id: dso-y1y6
status: closed
deps: [dso-awoz, dso-0y9j, dso-r9fa, dso-y9sz, dso-2x3c]
links: []
created: 2026-03-17T19:51:57Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-42eg
---
# Update project docs to reflect DSO script invocation via shim


## Notes

<!-- note-id: 59xwk620 -->
<!-- timestamp: 2026-03-17T19:53:19Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.

## What
Update CLAUDE.md and any other existing docs that reference the old $CLAUDE_PLUGIN_ROOT script invocation pattern to reflect the new shim-based workflow.

## Scope
IN: CLAUDE.md architecture section and quick reference table; any docs that describe script invocation patterns
OUT: Creating new documentation files

## Done Definitions
- When this story is complete, CLAUDE.md accurately describes shim invocation (.claude/scripts/dso) as the standard method for running DSO scripts from host projects
  ← Satisfies: overall epic goal of consistent, convenient DSO script invocation

<!-- note-id: zo1tehrn -->
<!-- timestamp: 2026-03-17T22:51:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: CLAUDE.md architecture section updated with shim invocation docs (SHA 565149b)
