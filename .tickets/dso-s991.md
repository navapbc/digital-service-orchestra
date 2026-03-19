---
id: dso-s991
status: closed
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


## Notes

**2026-03-18T23:43:38Z**


## Context
The preplanning skill generates user stories for epics but currently treats testing as an afterthought — unit tests are absent from story definitions of done, and test stories (E2E, integration) are either omitted or added ad-hoc without enforced dependency ordering. Orchestrators and implementing sub-agents are the primary beneficiaries: they receive stories with explicit TDD contracts rather than having to infer testing expectations from context. This epic owns the authoring contract (what stories look like when generated). Out of scope: any hook, gate, or enforcement mechanism that validates story compliance at commit or task-completion time — those belong to dso-ppwp.

## Success Criteria
- Stories with testable code changes include a "unit tests written and passing" checklist item in their definition of done; stories for documentation, research, or other non-code work do not require it
- When the preplanning skill classifies an epic as user-facing (LLM-inferred — semantic, not keyword-matching; examples: UI, screen, page, form, dashboard, or user-visible workflow), it includes an E2E test story; all implementation stories have the test story's ID in their depends_on list, and the test story's depends_on list contains no implementation story IDs from that epic
- When the preplanning skill classifies an epic as external-API (LLM-inferred; examples: HTTP endpoints, webhooks, third-party services, external service integration), it includes an integration test story with the same dependency structure
- When neither classification applies, the epic is treated as internal/infrastructure and no dedicated test story is added
- Test stories include an acceptance criterion stating all three obligations: tests must be run and confirmed failing (RED), before any implementation story begins, and the failing result must be recorded in a story note
- The updated skill, when exercised against a representative epic, produces stories where code-change stories have the unit testing DoD item, test stories (if any) have no implementation story IDs in their depends_on list, and all implementation stories depend on the test story

## Dependencies
None

## Approach
Add explicit TDD guidance directly to the preplanning skill's story-writing instructions so the story-generating agent naturally produces the correct DoD items, test stories, and dependency ordering without a separate classification step or audit pass.


<!-- note-id: yq6oc4nd -->
<!-- timestamp: 2026-03-19T01:06:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Epic complete: all tasks closed, validation score 5/5. TDD requirements integrated into preplanning SKILL.md with 7 GREEN structural tests.
