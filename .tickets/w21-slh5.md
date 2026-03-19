---
id: w21-slh5
status: closed
deps: [w21-auwy, w21-c4ek]
links: []
created: 2026-03-19T03:31:16Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-tmmj
---
# As a DSO practitioner, I can invoke dso:fix-bug with a cluster of related bugs investigated as a single problem

## Description

**What**: Cluster investigation — when dso:fix-bug is invoked with multiple bug IDs, investigate as a single problem and split into per-root-cause tracks when multiple independent root causes are identified.
**Why**: Related bugs often share a root cause. Investigating them individually wastes effort and may miss the shared cause. Investigating as a cluster and splitting only when needed is more efficient.
**Scope**:
- IN: Cluster invocation interface (accepting multiple bug IDs), cluster-to-single-problem investigation logic, root-cause-based splitting into independent tracks
- OUT: Integration with debug-everything's cluster dispatch (S7)

## Done Definitions

- When this story is complete, dso:fix-bug accepts a cluster of bug IDs and investigates them as a single problem
  ← Satisfies: "When invoked with a cluster of bugs, dso:fix-bug investigates them as a single problem"
- When this story is complete, the investigation splits into per-root-cause tracks only when multiple independent root causes are identified
  ← Satisfies: "splits into per-root-cause tracks only when the investigation identifies multiple independent root causes"

## Considerations

- [Testing] Test with mock clusters that have shared and independent root causes

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.
