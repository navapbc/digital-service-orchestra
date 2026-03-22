---
id: w22-jg2k
status: open
deps: []
links: []
created: 2026-03-22T06:46:06Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-5ooy
---
# As a DSO practitioner, tier reviewers carry lightweight security and performance classification checklist items

## Description

**What**: Add two permanent lightweight classification checklist items (security flag, performance flag) to all tier reviewer agents' reviewer-delta files.
**Why**: Provides fallback signal when deterministic classifier misses security/performance-relevant changes — the second layer of defense-in-depth.
**Scope**:
- IN: Two boolean checklist items added to each reviewer-delta file (light, standard, deep agents), items appear in reviewer output on every review
- OUT: Dispatch logic that reads these flags, overlay agent definitions

## Done Definitions

- When this story is complete, all tier reviewer agents include security and performance classification items in their reviewer-delta files
- When this story is complete, classification items appear in reviewer output for any diff regardless of flag value
- When this story is complete, the reviewer-delta files delivered by w21-ovpn exist before this story modifies them — this is a blocking external precondition
- When this story is complete, unit tests written and passing for checklist item presence

## Considerations

- [Maintainability] Consistent structure with existing reviewer-delta pattern from w21-ovpn
- [Ordering] w21-ovpn must deliver the reviewer-delta files first — this is a blocking external dependency at the epic level, not enforced by story-level deps. Do not begin this story until w21-ovpn reviewer-delta files exist.

