---
id: dso-0wi2
status: open
deps: []
links: []
created: 2026-03-17T18:33:41Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-9
---
# Project level config flags to modify behavior

We should implement a series of project configuration flags that modify the behavior of the workflow based on the nature of the project. 
One flag should indicate that the project has no UI, causing any references to design wireframe and design onboarding to skip and causing Playwright/visual validation logic to skip.
One flag should indicate that this project will be handling sensitive information (PII, PHI, CFI). This should trigger an additional step in the sprint skill, debug everything skill, and end session skill: a specialized sub-agent using opus that performs a security review of all commits before they are merged to main. This review should be skipped if there is nothing to merge. 
One flag should indicate that this is a hybrid project where changes will be made by both human and AI developers. When this flag is present, the workflow should be modified to replace merging to main with a PR process. This will mean that merge-to-main will need a second workflow that creates a PR instead of merging. Any workflow like debug everything or sprint that waits on CI completion will need to be modified to look for CI completion for the PR branch instead of main. When implementing this flag, we could carefully consider other workflow impacts of using PRs instead of merging directly to main.

