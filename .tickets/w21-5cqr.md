---
id: w21-5cqr
status: open
deps: []
links: []
created: 2026-03-19T03:30:24Z
type: bug
priority: 3
assignee: Joe Oakhart
jira_key: DIG-61
parent: dso-9xnr
---
# fix: document read-config.sh path anchoring in hook guards to prevent wrong relative path depth

When adding a monitoring.tool_errors guard (or any guard that calls read-config.sh) in a new hook file, the relative path to read-config.sh depends on where BASH_SOURCE[0] is anchored — not where HOOK_DIR points.

Correct patterns:
- Hook in plugins/dso/hooks/ (e.g., track-tool-errors.sh): HOOK_DIR is hooks/, so path is $HOOK_DIR/../scripts/read-config.sh (one ..)
- Hook sourced from plugins/dso/hooks/lib/ (e.g., session-misc-functions.sh): _HOOK_LIB_DIR is hooks/lib/, so path is $_HOOK_LIB_DIR/../../scripts/read-config.sh (two ..)

The task description for w21-kccl originally had $HOOK_DIR/../../scripts/ for track-tool-errors.sh (wrong — would look for plugins/scripts/ which does not exist). Because the guard uses 2>/dev/null || echo 'false', the failure is completely silent and monitoring is disabled with no warning.

Fix: Add a comment block to hooks/lib/session-misc-functions.sh and hooks/track-tool-errors.sh near the guard pattern explaining the correct depth calculation. Optionally add a test that verifies read-config.sh resolves to an existing path from each hook location.

