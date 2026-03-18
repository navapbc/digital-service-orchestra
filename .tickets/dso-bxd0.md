---
id: dso-bxd0
status: open
deps: []
links: []
created: 2026-03-18T04:36:55Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-igoj
---
# Audit current DSO setup path on macOS post-plugin-transition

As a DSO maintainer, I want a clear audit of what is stale or missing in the current setup path so that Stories B–E are grounded in reality rather than assumptions.

## Done Definition

- Written audit report (can be a markdown note or ticket note) listing:
  - All stale content in `docs/INSTALL.md` post-plugin-transition
  - All gaps in `scripts/dso-setup.sh` (missing prerequisite checks, missing hook installation, missing example config copying, etc.)
  - Any prerequisites or steps that exist in docs but not in the script, or vice versa
- Report is committed or attached to this ticket as a note before closing

## Escalation Policy

**If at any point you lack high confidence in your understanding of the existing project setup — e.g., you cannot determine whether a config pattern is intentional, whether a script step is still needed, or what the expected post-plugin-transition behavior should be — stop and ask the user before proceeding. Err on the side of guidance over assumption. This is a setup audit; mischaracterizing the current state will propagate errors into all downstream stories.**

