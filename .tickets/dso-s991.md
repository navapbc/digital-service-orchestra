---
id: dso-s991
status: open
deps: []
links: []
created: 2026-03-17T18:33:26Z
type: epic
priority: 0
assignee: Joe Oakhart
jira_key: DIG-1
---
# Integrate TDD into preplanning

Update the preplanning skill to incorporate TDD concepts when creating stories. Unit testing should be incorporated into the definition of done for individual stories, not into a separate story. For epics that involve a testable change in user facing functionality, a story should be included to create or update E2E testing. For epics involving changes to integrations with external APIs, a story should be created to create or update external integration tests. Stories to create or modify testing should be first in the dependency order, creating RED tests that are verified to fail before the epic has been implemented.

