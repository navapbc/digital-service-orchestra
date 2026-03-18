---
id: dso-ppwp
status: open
deps: []
links: []
created: 2026-03-17T18:34:10Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-26
---
# Add test gate enforcement

We can to add an enforcement mechanism to ensure that code isn’t committed with failing tests. This needs to account for performance issues that cause any long-running test suite to be terminated with an exit code 144. We want to use a similar pattern to what we use for review, where a fast commit hook verifies a secure hash before allowing the commit. Testing should be enforce on a you-touch-it-you-own-it basis. If a commit touches a test or code directly associated with the test (e.g. you change tool.py, then test_tool.py is associated), then the test must pass before commit.

