---
name: batch-overlap-check
description: Assess file overlap between batch candidate tasks and add dependencies to prevent parallel conflicts. Invoke as a sub-agent before launching parallel agent batches.
user-invocable: false
---

# Batch Overlap Check

Analyzes candidate tasks for a parallel batch and serializes any that would modify
the same files, preventing file-level conflicts between parallel sub-agents.

## When to Use

Invoke as a sub-agent from `/dso:debug-everything` Phase 3 before finalizing each
batch. Pass the candidate task IDs as input.

> **Note**: `/dso:sprint` Phase 3 now uses `sprint-next-batch.sh` instead, which
> handles story-level blocking propagation and file-overlap detection
> deterministically in a single script call without spawning a sub-agent.

## Input

The orchestrator provides:
- List of candidate task IDs for the batch
- Parent context (epic ID or tracker ID)

## Protocol

### Step 1: Extract Target Files (/dso:batch-overlap-check)

For each candidate task ID:
1. Run `.claude/scripts/dso ticket show <id>` to read the full description
2. Extract target files from the description:
   - **Explicit file paths** (e.g., `src/services/pipeline.py`)
   - **Module paths from error traces** (e.g., `src.models.document` -> `src/models/document.py`).
     For fully-qualified function or method names (e.g., `src.services.pipeline.process_document`),
     strip the trailing function/class/method components — convert only the module portion to a file
     path. Example: `src.services.pipeline.process_document` -> `src/services/pipeline.py`;
     `src.services.pipeline.Parser.parse` -> `src/services/pipeline.py`.
   - **Implied test files** (fixing `src/X.py` implies `tests/unit/.../test_X.py`)
   - **Shared config/init files** (e.g., `__init__.py`, `conftest.py` -- only flag if
     the task description explicitly mentions modifying exports or fixtures)

### Step 2: Build File -> Tasks Mapping (/dso:batch-overlap-check)

Create a mapping of each target file to the task(s) that reference it.
Report the mapping for orchestrator visibility.

### Step 3: Serialize Overlapping Tasks (/dso:batch-overlap-check)

For each file that appears in 2+ tasks:
1. Identify the higher-priority task (from ticket priority or batch priority class)
2. The lower-priority task should depend on the higher-priority one
3. **Circular dependency guard** before running `.claude/scripts/dso ticket link B A depends_on`:
   a. Run `.claude/scripts/dso ticket show A` and read its `blockedBy` field
   b. Walk the chain: for each ID in A's `blockedBy`, run `.claude/scripts/dso ticket show <id>` and check
      its `blockedBy` field (up to 5 levels deep -- sufficient for practical cases)
   c. If B appears anywhere in the chain -> adding B depends-on A would create a cycle
   d. **On cycle detection**: Do NOT add the dependency. Instead, report to the
      orchestrator: "Tasks A and B overlap on file X but cannot be serialized due to
      existing circular dependency. Recommend: run A in this batch, defer B to next."
4. If no cycle: run `.claude/scripts/dso ticket link <lower-priority> <higher-priority> depends_on`

### Step 4: Report (/dso:batch-overlap-check)

Output in this exact format:

```
OVERLAP CHECK COMPLETE
=====================
Candidate tasks: <id1>, <id2>, <id3>, ...

FILE OVERLAP MAP:
  <file path>: <task-id-1>, <task-id-2>
  <file path>: <task-id-3>, <task-id-4>
  (or "No overlaps detected")

DEPENDENCIES ADDED:
  <task-B> depends on <task-A> (overlap: <file>)
  (or "None")

CYCLE WARNINGS:
  <task-A> and <task-B> overlap on <file> but serialization blocked by cycle
  (or "None")

READY TASKS (post-serialization):
  <id1>, <id2>, ... (tasks safe to run in parallel)
```

### Rules
- Do NOT modify any code files
- Do NOT `git commit`, `git push`, `.claude/scripts/dso ticket transition`
- You CAN run `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket link`, `.claude/scripts/dso ticket list`
- Maximum 5 levels deep for cycle detection walk
