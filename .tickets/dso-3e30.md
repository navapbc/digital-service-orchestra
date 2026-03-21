---
id: dso-3e30
status: in_progress
deps: []
links: []
created: 2026-03-19T18:20:48Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-82
parent: dso-9xnr
---
# Bug: tk create -d interprets double-dash in description text as option flags

When passing a description via `tk create -d "text with -- in it"`, the double-dash
is interpreted as an option flag separator rather than literal text. This causes
"Unknown option: --" errors when descriptions contain phrases like "DSO_ROOT came
from the config fallback -- when Claude Code sets it correctly".

Also affects nohup-launch.sh since it passes arguments through eval, which re-parses
the description string.

Repro: `tk create "test" -t task -d "foo -- bar"`
Expected: task created with description "foo -- bar"
Actual: "Unknown option: --"

## Notes

<!-- note-id: e39g8u7l -->
<!-- timestamp: 2026-03-21T00:20:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed. Root cause: (1) cmd_create in tk lacked a -- stop-parsing sentinel case; bare -- hit the -*) catch-all and returned 'Unknown option: --'. (2) nohup-launch.sh used eval "${*:5}" which re-parses args, splitting quoted strings like 'foo -- bar' into tokens foo -- bar, causing -- to reach the parser as a discrete arg. Fix: added -- case to cmd_create parser; updated nohup-launch.sh to use "${@:5}" exec (not eval) when multiple command args are passed, preserving eval path for single shell-string arg (pipes/redirects). Tests: tests/scripts/test-tk-create-double-dash.sh (new, 3 cases).
