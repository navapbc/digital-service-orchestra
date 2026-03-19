---
id: dso-3e30
status: open
deps: []
links: []
created: 2026-03-19T18:20:48Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-82
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
