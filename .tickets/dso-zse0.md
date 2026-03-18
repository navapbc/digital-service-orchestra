---
id: dso-zse0
status: open
deps: [dso-hmb3]
parent: dso-6524
links: []
created: 2026-03-18T18:47:52Z
type: story
priority: 2
assignee: Joe Oakhart
---
# As a DSO developer, all path references in CLAUDE.md reflect the post-restructure layout so the guide remains accurate


## Notes

**2026-03-18T18:49:44Z**


## What
Audit and update all path references in the project CLAUDE.md covering scripts/, hooks/, docs/, and commands/ references to use .claude/scripts/dso shim form or the new plugins/dso/ prefix as appropriate. Create examples/CLAUDE.md.example as a Quick Reference template for client projects.

## Why
After the restructure, direct paths like scripts/validate.sh and hooks/dispatchers/ in CLAUDE.md become stale. This story ensures the primary developer guide stays accurate and provides a client-facing template.

## Scope
IN: Audit and update all bare scripts/, hooks/, commands/, docs/ path references in CLAUDE.md; create examples/CLAUDE.md.example with min. 8 shim-form Quick Reference rows
OUT: Updating docs/ subdirectory files (dso-1f7p); changes to dso-setup.sh (dso-7idt)

## Done Definitions
- When this story is complete, grep check for bare path refs in CLAUDE.md and examples/CLAUDE.md.example returns no matches (excluding .claude/scripts/dso and plugins/dso/ prefixed references)
  <- Satisfies: no bare path references remain in CLAUDE.md or example
- When this story is complete, examples/CLAUDE.md.example exists and contains a Quick Reference table with at least 8 DSO commands in shim form (.claude/scripts/dso <script-name>)
  <- Satisfies: distributed example CLAUDE.md uses shim-form references

## Considerations
- [Maintainability] Audit covers scripts/, hooks/, and commands/ references — not just scripts/ as originally scoped; the Architecture section of CLAUDE.md contains hooks/dispatchers/, hooks/lib/review-gate-allowlist.conf and similar paths that will be stale after S1
- [Maintainability] Systematic scan: run grep across CLAUDE.md first to inventory all references before updating
- [Reliability] After removing direct path references, confirm the DSO development repo can bootstrap the shim locally (run bash plugins/dso/scripts/dso-setup.sh . or document an alternative bootstrap path for developers)

