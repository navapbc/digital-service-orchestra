---
name: tickets-health
description: Issue health validation and remediation
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Issue Health Validation

## When to Run

```bash
.claude/scripts/dso validate-issues.sh          # Standard check
.claude/scripts/dso validate-issues.sh --verbose # Detailed output
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
4. After fixing issues, re-run `.claude/scripts/dso validate-issues.sh` to confirm score improves

## Common Issues and Fixes

### Orphaned Prefixed Task

Task has prefix (MC-, V-, A-, I-, L-, RR-) but no parent epic.

```bash
# Find the appropriate epic
.claude/scripts/dso ticket list --type=epic

# Assign parent (use add-note to record the epic association)
.claude/scripts/dso ticket comment <task-id> "Parent epic: <epic-id>"
```

### Task Listed as Dependency Instead of Child

Epic depends on task, but task should be a child of epic.

```bash
# Remove incorrect dependency (.claude/scripts/dso ticket unlink <id1> <id2> to remove a link; note to user)
# Use .claude/scripts/dso ticket comment to record the correct parent association
.claude/scripts/dso ticket comment <task-id> "Parent epic: <epic-id> (was incorrectly set as dep)"
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
.claude/scripts/dso ticket show <task-id>  # Check blockedBy

# Break the cycle (use `.claude/scripts/dso ticket unlink <id1> <id2>` to break the cycle)
# Document the cycle with a note:
.claude/scripts/dso ticket comment <task-a> "Circular dependency detected with <task-b> — review and break manually"
```

### Interface Task Without Documentation

Task mentions "interface", "contract", "abstract", or "protocol" but has no notes documenting the file path and key methods.

```bash
.claude/scripts/dso ticket comment <task-id> "Interface: src/path/to/base.py
Key methods: method1(), method2()
Constraint: Must be thread-safe"
```

### High-Impact Blocker (3+ tasks blocked)

When 3 or more tasks are blocked by the same task, consider extracting an interface contract to enable parallel work.

```bash
# Check what's blocked
.claude/scripts/dso ticket show <blocking-task-id>

# If >3 tasks blocked, create interface contract
.claude/scripts/dso ticket create task "Define interface contract for <feature>" --priority 1

# Then add implementations as separate tasks that depend on the interface
.claude/scripts/dso ticket create task "Implement ConcreteA" --priority 2
.claude/scripts/dso ticket link <impl-task-id> <interface-task-id> depends_on
```

## Interface Contract Validation

The validation script checks for:
- **Interface tasks without documentation**: Tasks mentioning "interface", "contract", "abstract", or "protocol" should have notes documenting the file path and key methods
- **Parallelization opportunities**: When 3+ tasks are blocked by the same task, it suggests extracting an interface contract to enable parallel work

These checks encourage designing for parallel agent development by identifying tasks that could benefit from formal interface definitions.

## Task State Machine

```
States: pending → in_progress → completed
  pending:      Ready if no blockers and not assigned. Created via `.claude/scripts/dso ticket create`.
  in_progress:  Agent actively working. Set via `.claude/scripts/dso ticket transition <id> in_progress`.
                Can revert to pending if blocked by dependency.
  completed:    Only after CI passes and all acceptance criteria met. Set via `.claude/scripts/dso ticket transition`.
```
