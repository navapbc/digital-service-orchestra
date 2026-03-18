---
id: dso-uvyl
status: open
deps: []
links: []
created: 2026-03-17T18:34:16Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-29
---
# Make implementation plan migration aware

Implement plan should look for migration patterns, and create cleanup tasks when necessary to avoid accumulation of code debt and documentation debt. For example, tests that confirm a successful migration should be removed after the migration completes and the tests pass. Tests that validate current behavior or prevent regression should remain. As an example, after our migration from bd to tk we had a number of tests that checked for tk being used instead of bd. Those tests were appropriate during the migration, but afterwards they provided no meaningful validation of our code. Documentation cleanup should involve moving design and planning documents for completed features to an archive folder. It should involve archiving known issues that are no longer relevant to the project's implementation.

