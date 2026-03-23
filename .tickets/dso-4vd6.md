---
id: dso-4vd6
status: open
deps: []
links: []
created: 2026-03-22T16:50:25Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-fldu
---
# RED: Write failing tests for blocker ID output in sprint-list-epics.sh

Add tests to tests/scripts/test-sprint-list-epics.sh. Add fixtures: epic-f (deps [task-x, epic-a]), epic-g (deps [task-x, task-y]). Test 19: BLOCKED epic-d has task-x in 6th field. Test 20: epic-f has task-x,epic-a in 6th field. Test 21: epic-g has only task-x (task-y closed). Add .test-index RED marker.

