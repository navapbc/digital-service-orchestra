---
id: dso-t4k8
status: open
deps: []
links: []
created: 2026-03-17T18:34:33Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-38
---
# Don't cover up problems

Using lockpicks and debugging skills and review resolution prompts should provide guidance that agents should fix errors instead of covering them to. Our goal is to prevent the anti-pattern of agents skipping tests, adding inline exceptions to lint rules, increasing error tolerance levels, and other behavior that quickly resolves a failure without addressing the underlying issue. We want to fix the problem, not remove visibility into the problem. 
Code review agents should be instructed to apply additional scrutiny to inline lint exceptions, skipped tests, and other changes that reduce visibility into problems.

