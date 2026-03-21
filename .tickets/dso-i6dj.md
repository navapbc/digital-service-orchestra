---
id: dso-i6dj
status: in_progress
deps: []
links: []
created: 2026-03-19T18:55:34Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-9xnr
---
# Bug: /dso:brainstorm created children with truncated titles and descriptions


## Notes

<!-- note-id: ampu4uz7 -->
<!-- timestamp: 2026-03-19T18:55:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

3 of 4 children created by /dso:brainstorm for epic dso-jt4w have truncated/corrupted titles and descriptions: dso-hpbh ('scripts.' / 'Remove'), dso-taha ('.claude/scripts/dso:' / 'Add'), dso-drn9 ('resolution:' / 'Replace'). Only dso-ilna has a proper title and description. The brainstorm skill appears to have truncated ticket content during creation.

<!-- note-id: 1my3rq58 -->
<!-- timestamp: 2026-03-21T00:29:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: behavioral, Score: 2 (BASIC). Root cause: tk create only captures the LAST positional arg as the title. When the LLM generates tk create commands with unquoted multi-word titles (e.g., tk create Remove scripts. -t task), each positional arg overwrites the previous, leaving only the last word as the title. Similarly, unquoted description args get truncated to one word. Fix: accumulate all positional args into title with space-joining instead of last-wins.
