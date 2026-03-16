---
name: tickets-health
description: Issue health validation and remediation
user-invocable: true
---

# Issue Health Validation

## When to Run

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/validate-issues.sh          # Standard check
${CLAUDE_PLUGIN_ROOT}/scripts/validate-issues.sh --verbose # Detailed output
```

**Run after**:
- Creating one or more new tasks
- Setting up dependencies between tasks
- Re-parenting tasks under epics
- When batch-creating tasks, run **once** after all tasks and initial relationships are created

## Score Interpretation

```
Score 5 (Excellent) → Proceed with work
Score 4 (Good)      → Fix if convenient
Score 3 (Fair)      → MUST fix before continuing
Score 2 (Poor)      → STOP - significant issues
Score 1 (Critical)  → IMMEDIATE action required
```

| Score | Meaning | Action Required |
|-------|---------|-----------------|
| 5 | Excellent | None - proceed with work |
| 4 | Good | Minor issues - fix if convenient |
| 3 | Fair | **Must fix** before continuing |
| 2 | Poor | **Stop and fix** - significant issues |
| 1 | Critical | **Immediate action** - blocking issues |

## If Score < 5

1. Review the issues reported by the script
2. **Ask the user for clarification** before making significant changes to task descriptions, epic assignments, or dependency structures
3. Prefer clarification over assumptions when:
   - Task belongs to multiple possible epics
   - Dependency direction is ambiguous
   - Task description conflicts with epic goals
4. After fixing issues, re-run `${CLAUDE_PLUGIN_ROOT}/scripts/validate-issues.sh` to confirm score improves

## Common Issues and Fixes

### Orphaned Prefixed Task

Task has prefix (MC-, V-, A-, I-, L-, RR-) but no parent epic.

```bash
# Find the appropriate epic
tk ready; tk blocked

# Assign parent (use add-note to record the epic association)
tk add-note <task-id> "Parent epic: <epic-id>"
```

### Task Listed as Dependency Instead of Child

Epic depends on task, but task should be a child of epic.

```bash
# Remove incorrect dependency (tk does not have dep remove; note to user)
# Use tk add-note to record the correct parent association
tk add-note <task-id> "Parent epic: <epic-id> (was incorrectly set as dep)"
```

### Empty Epic

Epic has no children or all children are closed.

**Do NOT close empty epics.** Epics represent planned work that needs decomposition.
Run `/dso:preplanning <epic-id>` to break the epic into user stories and tasks.

```bash
# Decompose the epic into child tasks
/dso:preplanning <epic-id>
```

Only close an epic if the user explicitly confirms it is obsolete.

### Circular Dependency

Task A blocks B, B blocks A (directly or through chain).

```bash
# Find the cycle
tk show <task-id>  # Check blockedBy

# Break the cycle (tk does not have dep remove; contact user to resolve manually)
# Document the cycle with a note:
tk add-note <task-a> "Circular dependency detected with <task-b> — review and break manually"
```

### Interface Task Without Documentation

Task mentions "interface", "contract", "abstract", or "protocol" but has no notes documenting the file path and key methods.

```bash
tk add-note <task-id> "Interface: src/path/to/base.py
Key methods: method1(), method2()
Constraint: Must be thread-safe"
```

### High-Impact Blocker (3+ tasks blocked)

When 3 or more tasks are blocked by the same task, consider extracting an interface contract to enable parallel work.

```bash
# Check what's blocked
tk show <blocking-task-id>

# If >3 tasks blocked, create interface contract
tk create "Define interface contract for <feature>" -t task -p 1

# Then add implementations as separate tasks that depend on the interface
tk create "Implement ConcreteA" -t task -p 2
tk dep <impl-task-id> <interface-task-id>
```

## Interface Contract Validation

The validation script checks for:
- **Interface tasks without documentation**: Tasks mentioning "interface", "contract", "abstract", or "protocol" should have notes documenting the file path and key methods
- **Parallelization opportunities**: When 3+ tasks are blocked by the same task, it suggests extracting an interface contract to enable parallel work

These checks encourage designing for parallel agent development by identifying tasks that could benefit from formal interface definitions.

## Task State Machine

```
States: pending → in_progress → completed
  pending:      Ready if no blockers and not assigned. Created via `tk create`.
  in_progress:  Agent actively working. Set via `tk status <id> in_progress`.
                Can revert to pending if blocked by dependency.
  completed:    Only after CI passes and all acceptance criteria met. Set via `tk close`.
```
