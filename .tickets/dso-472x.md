---
id: dso-472x
status: open
deps: []
links: []
created: 2026-03-18T04:41:08Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-igoj
---
# preplanning: tk create calls omit story description and done definition

During Phase 4 (Create Stories), the preplanning skill instructs the agent to run tk create with only a title. The done definition, user story narrative, and adversarial review considerations assembled during Phases 2–3 are never passed to tk create via --description or --acceptance. Story tickets are created as bare titles with no body, requiring manual backfill after the fact.

## Acceptance Criteria

preplanning Phase 4 passes the done definition and user story body to tk create (via --description and/or --acceptance) so stories are complete at creation time

