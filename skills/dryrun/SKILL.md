---
name: dryrun
description: Use when the user wants to preview what a skill would do without making changes to beads, the file system, or git
user-invocable: true
---

# Dryrun Mode

Preview what a skill would do without making any changes.

## Usage

```
/dryrun /roadmap
/dryrun /dev-onboarding
/dryrun /preplanning <epic-id>
```

## Rules

When dryrun mode is active, follow the target skill's full workflow but apply these overrides:

### Do NOT execute

- `bd` commands (create, update, close, dep add, epic create)
- File writes (`Write`, `Edit`, `NotebookEdit`)
- Git commands (commit, push, add)
- Any script that modifies state

### DO execute

- Read-only commands (`bd list`, `bd show`, `bd ready`, `git status`, `git log`)
- File reads (`Read`, `Glob`, `Grep`)
- Check scripts (`check-onboarding.sh`, `validate-beads.sh`)
- `AskUserQuestion` — the interview/dialogue portions run normally

### Output format

For every action that would modify state, show it as a preview block:

```
[DRYRUN] Would run: bd epic create "Phase 1: Authentication System" -p 1
[DRYRUN] Would write: DESIGN_NOTES.md (47 lines)
[DRYRUN] Would run: bd dep add beads-042 beads-041
```

For file writes, show the full content that would be written inside a fenced code block after the `[DRYRUN]` line.

### At completion

Summarize all deferred actions:

```
=== Dryrun Summary ===
Files that would be created/modified: [list]
Beads commands that would run: [list]
Git operations that would run: [list]

To execute for real, run the skill without /dryrun.
```
