---
id: dso-qo0x
status: open
deps: []
links: []
created: 2026-03-17T18:34:00Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-19
---
# Incorporate OpenRewrite

OpenRewrite by Moderne | Large Scale Automated Refactoring | OpenRewrite Docs https://share.google/rcPhhf99z4tDtge9P
This tool should be used to identify and correct patterns. When we fix a bug, we should evaluate whether an OpenRewrite recipe can be used to identify other occurrences of the bug. When we change a signature or variable name with scope beyond one file, this tool can be used to identify tests or other files that reference what we're changing. We should validate that the statements in this ticket are correct, assess the capabilities of this tool, and incorporate it into skills and guidance to increase the reliability of our development process without using additional LLM tokens.
Use the LLM to identify which OpenRewrite recipe to run or to write a custom YAML recipe, then let the OpenRewrite engine execute the transformation across thousands of files with 100% precision.

