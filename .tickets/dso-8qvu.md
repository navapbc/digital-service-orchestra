---
id: dso-8qvu
status: in_progress
deps: []
links: []
created: 2026-03-18T01:14:42Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Qualify all DSO skill references to /dso: namespace


## Notes

**2026-03-18T01:14:56Z**


## Context
DSO plugin contributors and engineers integrating DSO into a new host project encounter ambiguity when reading skill invocations in workflow files. When a workflow references `/review` or `/sprint`, it is impossible to determine by inspection whether the call targets a DSO skill or a command from another provider. With approximately 270 such unqualified references across 60+ files, a new contributor must grep the skill registry to resolve ownership for every invocation they encounter. Fully qualifying all references to their `/dso:` equivalents makes each invocation self-documenting and eliminates namespace collision risk as the plugin ecosystem grows.

## Scope Boundary
This epic owns qualification of all existing DSO skill references in the current codebase layout. It does not restructure directories or rename skills. `dso-6524` is responsible for updating `check-skill-refs.sh`'s in-scope file set if it restructures the directory layout.

## Deliverables
- `scripts/check-skill-refs.sh` — linter: exits non-zero on unqualified refs, exits 0 when clean
- `scripts/qualify-skill-refs.sh` — one-shot bulk rewriter; whole-word-match only (e.g. `/review-gate` not touched); idempotent (double-run produces no changes)

## Definition
An 'unqualified reference' is `/<skill-name>` not prefixed with `dso:` and not inside a URL (not preceded by `://`). Qualified form: `/dso:<skill-name>` — leading slash retained, `dso:` inserted after it (e.g. `/sprint` → `/dso:sprint`).

## Success Criteria
- `scripts/check-skill-refs.sh` exits non-zero when any in-scope file contains an unqualified reference to any skill in the canonical list: sprint, commit, review, end, tdd-workflow, implementation-plan, preplanning, debug-everything, brainstorm, plan-review, interface-contracts, resolve-conflicts, retro, roadmap, oscillation-check, design-onboarding, design-review, ui-discover, dev-onboarding, validate-work, tickets-health, playwright-debug, dryrun, quick-ref, fix-cascade-recovery.
- In-scope file set for both scripts: all files under skills/, docs/, hooks/, and commands/ (recursively, no symlinks), plus CLAUDE.md. All file extensions included.
- After running qualify-skill-refs.sh, check-skill-refs.sh exits 0 on all in-scope files.
- check-skill-refs.sh is added to scripts/validate.sh as a fatal check.
- tests/scripts/test-check-skill-refs.sh verifies: (a) exit non-zero on unqualified ref (RED), (b) exit 0 after qualification (GREEN).
- tests/scripts/test-check-skill-refs.sh includes three negative cases: URL, already-qualified /dso:sprint, hyphenated /review-gate.
- A first-time DSO contributor can identify skill ownership in skills/, docs/, or commands/ by reading the call site alone.

## Dependencies
This epic must complete before dso-6524 (Separate DSO plugin from DSO project) restructures the directory layout. No blocking upstreams. Parallel-edit note: both this epic and dso-ppwp (Add test gate enforcement) modify scripts/validate.sh — coordinate merge order.

## Approach
Option A: Automated bulk replace. Write scripts/qualify-skill-refs.sh (one-shot sed-based replacement) and scripts/check-skill-refs.sh (lint rule). Run qualify-skill-refs.sh on the codebase. Register check-skill-refs.sh in validate.sh as a permanent CI check.

