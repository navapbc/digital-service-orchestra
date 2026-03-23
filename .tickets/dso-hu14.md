---
id: dso-hu14
status: open
deps: [dso-1cje, dso-yv90]
links: []
created: 2026-03-23T15:20:45Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-wbqz
---
# Update documentation and CLAUDE.md prose with ticket CLI references

Update all skill files, documentation files, and CLAUDE.md to use ticket CLI commands instead of tk commands where ticket equivalents exist. The tk wrapper remains for Jira sync and tk-only commands.

## test-exempt justification
test-exempt: (1) no conditional logic — pure prose/text replacement; (2) any test written would be a change-detector test asserting strings exist in files, not behavioral tests; (3) documentation-boundary-only with no business logic.

## Depends on
dso-1cje (infrastructure updates must be complete)
dso-yv90 (hook behavioral guards must be finalized)

## Enumerated Replacement Patterns
Apply these specific patterns (NOT blanket s/tk/ticket/g):

REPLACE:
  tk show <id>          → ticket show <id>
  tk create             → ticket create
  tk list               → ticket list
  tk dep tree <id>      → ticket deps <id>
  tk status <id> <s>    → ticket transition <id> <current> <s>
  tk close <id>         → ticket transition <id> open closed
  tk open <id>          → ticket transition <id> closed open
  tk add-note <id>      → ticket comment <id>
  tk comment <id>       → ticket comment <id>
  tk transition <id>    → ticket transition <id>

KEEP AS-IS (tk wrapper only):
  tk sync               → tk sync (Jira bridge; no ticket equivalent)
  tk ready              → tk ready (tk-wrapper query; no ticket equivalent)
  tk blocked            → tk blocked (tk-wrapper query; no ticket equivalent)
  tk dep <child> <p>    → (handled in T3 as closed-parent-guard context; in docs: ticket link)

## Files to Update

### CLAUDE.md (8 tk references)
- Line 52 quick reference table: 'tk sync' — KEEP (Jira bridge)
- Line 60 prose: 'the higher-level tk wrapper adds Jira sync' — KEEP (accurate description)
- Line 61 prose: 'Epic closure enforcement: tk close <epic-id>' → 'ticket transition <epic-id> open closed'
- Lines 127/128 Always Do These: 'tk sync', 'tk write commands' — KEEP (timeout guidance for tk sync)
- Line 142 Plan Mode: 'Create tk epic' → 'Create ticket epic' (or just 'Create epic' — the command is 'tk create ... -t epic' currently; update to 'ticket create ...')
- Line 160 Session close: 'not the tk Session Close Protocol' — KEEP if this refers to a known legacy doc

### plugins/dso/skills/ (45 files)
Apply enumerated replacement patterns above. Key files:
- plugins/dso/skills/sprint/SKILL.md: many tk show/create/status/close/ready/dep-tree refs
- plugins/dso/skills/fix-bug/SKILL.md
- plugins/dso/skills/implementation-plan/SKILL.md (already reviewed — apply patterns)
- plugins/dso/skills/preplanning/SKILL.md
- All other SKILL.md and prompt files with tk refs

### plugins/dso/docs/ (23 files)
Apply enumerated replacement patterns. Key files:
- plugins/dso/docs/workflows/COMMIT-WORKFLOW.md: 'tk add-note' → 'ticket comment'
- plugins/dso/docs/workflows/REVIEW-WORKFLOW.md: same
- plugins/dso/docs/ticket-cli-reference.md: update any tk show/create examples that should use ticket CLI
- plugins/dso/docs/WORKTREE-GUIDE.md
- plugins/dso/docs/INSTALL.md
- plugins/dso/docs/SUB-AGENT-BOUNDARIES.md

## Post-Update Verification (required ACs — verification gate)
After all documentation updates complete:

1. Enumerate-patterns grep (must return NO matches):
   grep -rn '\btk show\b\|\btk create\b\|\btk close\b\|\btk add-note\b\|\btk status\b\|\btk transition\b\|\btk dep tree\b' plugins/dso/skills/ plugins/dso/docs/ CLAUDE.md

2. Remaining tk refs grep (all surviving hits must be tk-wrapper-only commands):
   grep -rn '\btk\b' plugins/dso/skills/ plugins/dso/docs/ CLAUDE.md plugins/dso/hooks/
   Verify all hits are: tk sync, tk ready, tk blocked, tk dep (as legacy reference), or prose descriptions of the tk wrapper

3. Syntax validation on all modified .sh files:
   bash -n plugins/dso/hooks/lib/pre-bash-functions.sh
   bash -n plugins/dso/hooks/closed-parent-guard.sh
   bash -n plugins/dso/hooks/bug-close-guard.sh
   bash -n plugins/dso/hooks/compute-diff-hash.sh
   bash -n plugins/dso/scripts/merge-to-main.sh

4. Python syntax validation:
   python3 -m py_compile plugins/dso/scripts/merge-ticket-index.py

5. Test suite:
   bash tests/run-all.sh

