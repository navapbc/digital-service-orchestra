---
id: w22-rkur
status: open
deps: [w22-5e4i, w22-opu1]
links: []
created: 2026-03-21T16:58:51Z
type: story
priority: 3
assignee: Joe Oakhart
parent: w22-528r
---
# Update project docs to reflect test suite discovery

## Description

**What**: Update CLAUDE.md and relevant docs to document --suites flag, JSON output schema, config key format, and discovery heuristics.
**Why**: Future agents need accurate awareness of the new discovery capability.
**Scope**:
- IN: CLAUDE.md architecture section, dso-config.conf key documentation
- OUT: New documentation files (update existing only)

## Done Definitions

- When this story is complete, CLAUDE.md references project-detect.sh --suites and its JSON output schema
  ← Satisfies: "project documentation is accurate"
