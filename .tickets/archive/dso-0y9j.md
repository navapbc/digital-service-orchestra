---
id: dso-0y9j
status: closed
deps: [dso-awoz]
links: []
created: 2026-03-17T19:51:55Z
type: story
priority: 0
assignee: Joe Oakhart
parent: dso-42eg
---
# As a DSO hook or script author, I can source the shim in library mode to get DSO_ROOT without depending on CLAUDE_PLUGIN_ROOT


## Notes

<!-- note-id: 5e4a9hxi -->
<!-- timestamp: 2026-03-17T19:52:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## What
Add library mode (`--lib` flag) to the shim so DSO hooks and scripts can source it to obtain DSO_ROOT.

## Why
Hooks and scripts need DSO_ROOT to locate other plugin resources. Sourcing the shim in library mode gives them the same reliable resolution logic without requiring a separate resolver.

## Scope
IN: `--lib` flag that runs the cascading DSO_ROOT resolution and exports `DSO_ROOT`, produces no stdout; library mode must not dispatch any script
OUT: The dispatch logic itself [S1], error handling for missing plugin (same cascading lookup as S1)

## Done Definitions
- When this story is complete, `source .claude/scripts/dso --lib && echo $DSO_ROOT` prints the absolute plugin path
  ← Satisfies: 'A DSO hook or script can obtain DSO_ROOT by sourcing the shim in library mode'
- When this story is complete, library mode produces no stdout
  ← Satisfies: 'Library mode exports only DSO_ROOT and produces no stdout'
- When this story is complete, DSO_ROOT is exported and readable by the sourcing script
  ← Satisfies: 'A DSO hook or script can obtain DSO_ROOT...and reading the exported DSO_ROOT variable'

<!-- note-id: 0itg4q53 -->
<!-- timestamp: 2026-03-17T22:20:57Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Implemented: --lib flag in templates/host-project/dso; all lib-mode tests pass
