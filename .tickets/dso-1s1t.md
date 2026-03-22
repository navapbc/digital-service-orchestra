---
id: dso-1s1t
status: open
deps: [dso-ncv2]
links: []
created: 2026-03-22T16:50:26Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-fldu
---
# GREEN: Add BLOCKING marker to blocking epics + update existing tests

Build blocking_ids set. Prepend BLOCKING to output for blocking epics. Update Test 6 to handle BLOCKING prefix. Update Test 7 to filter BLOCKING lines and adjust expected order. Search for other sprint-list-epics.sh consumers. Remove .test-index RED marker.

