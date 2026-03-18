---
id: dso-lwcp
status: open
deps: []
links: []
created: 2026-03-17T18:33:51Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-14
---
# Retro skill should include an overall visual review

For applications with a visual UI, the retro skill should include a comprehensive visual review of the application. We should use some of our existing UI/wireframe/visual/design prompts as a starting point for reviewing the existing application. We should refine these prompts to reflect the fact that we are reviewing the application as a whole, not a single design change being implemented. The visual review should used a similar tiered system to our visual validation: optimizing for scripted analysis while allowing for escalation to Playwright when we need to evaluate more complex functionality.
The addition to retro should consist of:
A critical investigative pass through the lens of a red team
A blue-team pass to filter out false positives and low-user-impact findings
Creation of user stories to address each remaining finding, grouping findings by component or screen modified. Each story should be parented to the epic the retro skill creates.
Running design-wireframe on each story to plan the design change.

