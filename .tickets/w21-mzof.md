---
id: w21-mzof
status: closed
deps: []
links: []
created: 2026-03-20T02:31:49Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Cross-component contract detection in /dso:implementation-plan


## Notes

**2026-03-20T02:31:58Z**


## Context
When a DSO developer runs /dso:sprint on an epic that touches multiple components needing a shared interface (signal formats, prompt schemas, report structures), the current planning flow doesn't surface these contracts explicitly. They get discovered during code review when the two sides don't match — as happened with the fix-bug/debug-everything ESCALATION_REPORT contract in epic w21-25vk, where fix-bug emitted a signal format that debug-everything couldn't parse, requiring 3 review resolution cycles to align. By detecting cross-component contracts during /dso:implementation-plan and creating a contract definition task that other tasks depend on, developers avoid wasting review cycles on interface alignment that should have been resolved at planning time.

## Success Criteria
1. When /dso:implementation-plan detects that a story's file impact spans two or more components that exchange structured data (one emits, the other parses), it creates a contract definition task as the first task in the dependency chain — the contract task produces a concrete artifact (schema definition in a markdown or JSON file under plugins/dso/docs/contracts/ or plugins/dso/skills/shared/) that downstream implementation tasks reference in their acceptance criteria
2. The detection heuristic covers two v1 contract patterns: (a) signal emit/parse pairs — where one skill/script produces a structured output format (e.g., STATUS:, ESCALATION_REPORT:) that another skill/script parses, and (b) orchestrator/sub-agent report schemas — where a sub-agent returns structured data the orchestrator must interpret. Additional patterns (shared prompt placeholders, cross-skill dispatch formats) are deferred to follow-on work
3. Cross-story contract deduplication: when /dso:implementation-plan runs on a story, it checks existing tasks under the parent epic (tk dep tree <epic-id>) for a contract task covering the same interface before creating a new one — if found, it wires the new story's tasks as dependents of the existing contract task via tk dep
4. After delivery, run /dso:sprint on the next 3 epics that involve cross-component changes and track whether review resolution cycles for contract-related findings decrease — target: 0 contract-mismatch findings requiring review fix/defend cycles (baseline: 3 cycles on w21-25vk)

## Dependencies
None (file-impact analysis already exists in /dso:implementation-plan)

## Approach
Enhance /dso:implementation-plan's task generation step to include a contract detection pass after file impact analysis. When the file impact list contains components on both sides of an interface boundary, generate a contract definition task whose deliverable is the shared artifact. Use tk dep tree to check for existing contract tasks before creating duplicates.

