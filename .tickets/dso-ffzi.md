---
id: dso-ffzi
status: open
deps: []
links: []
created: 2026-03-17T18:33:28Z
type: epic
priority: 0
assignee: Joe Oakhart
jira_key: DIG-2
---
# Integrate TDD into implementation plan skill

TDD principles should be incorporated into the implementation plan skill. Stories that change code should start by writing a RED unit test that fails, and require tests to pass as one of the acceptance criteria for the task that completes the relevant code changes. Writing RED tests must be a separate task that is a dependency of writing implementation code. This should not be the only acceptance criteria. All tasks created by implementation plan should include acceptance criteria following the same logic the sprint skill uses to add acceptance criteria to tasks that are missing them. Testing should pass hypothesis assertion density standards and code coverage standards. When implementing this epic, we need to investigate patterns used to identify code that would be unreasonable to cover with unit tests. We want to provide an escape hatch for stories where adding unit tests would not be follow testing best practices, but we need to safeguard against agents using this escape hatch to avoid writing unit tests that would be required by testing best practices.

