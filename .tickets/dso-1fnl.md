---
id: dso-1fnl
status: closed
deps: []
links: []
created: 2026-03-17T18:34:35Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-39
---
# Implement review guidance related to code reuse

Agents commonly generate code that duplicates functionality already present in the codebase. For example, generating a new type instead of reusing or extending an existing type. We want to update our code review prompt to explicitly search for similar code that already exists, protecting us from creating the same or similar functionality repeatedly.
All repeated code shouldn’t necessarily be consolidated. We should include guidance for how to differentiate code that should be reusable from code where centralization or abstraction would create a maintenance burden. We should use websearch and webfetch when writing this guidance (not when performing the review) to research expert guidance on how to distinguish between duplicate code that should be consolidated and duplicate code that should remain separate.

