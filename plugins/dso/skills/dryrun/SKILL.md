---
name: dryrun
description: Use when the user wants to dry-run a DSO skill, simulate its execution, or preview its planned changes without executing them. Wraps any /dso:* skill invocation with override rules that block all mutating operations (ticket writes, file edits, git commits) while still running read-only steps; emits [DRYRUN] preview blocks for each blocked mutation and a final summary of what would have changed. Trigger phrases include 'dry run', 'simulate', 'what-if', 'test run', 'no-op', 'preview without changes', 'show me what would happen'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Dryrun Mode

Preview what a skill would do without making any changes.

## Usage

```
/dso:dryrun /dso:roadmap
/dso:dryrun /dso:architect-foundation
/dso:dryrun /dso:preplanning <epic-id>
```

## Rules

When dryrun mode is active, follow the target skill's full workflow but apply these overrides:

### Do NOT execute

- ticket CLI commands that modify state (`.claude/scripts/dso ticket create`, `.claude/scripts/dso ticket transition`, `.claude/scripts/dso ticket link`, `.claude/scripts/dso ticket comment`)
- File writes (`Write`, `Edit`, `NotebookEdit`)
- Git commands (commit, push, add)
- Any script that modifies state

### DO execute

- Read-only commands (`.claude/scripts/dso ticket list [--type=<type>] [--status=<status>] [--parent=<id>] [--format=llm]`, `.claude/scripts/dso ticket show`, `git status`, `git log`)
- File reads (`Read`, `Glob`, `Grep`)
- Check scripts (`check-onboarding.sh`, `validate-issues.sh`)
- `AskUserQuestion` — the interview/dialogue portions run normally

### Output format

For every action that would modify state, show it as a preview block:

```
[DRYRUN] Would run: .claude/scripts/dso ticket create epic "Phase 1: Authentication System" --priority 1
[DRYRUN] Would write: .claude/design-notes.md (47 lines)
[DRYRUN] Would run: .claude/scripts/dso ticket link ticket-042 ticket-041
```

For file writes, show the full content that would be written inside a fenced code block after the `[DRYRUN]` line.

### At completion

Summarize all deferred actions:

```
=== Dryrun Summary ===
Files that would be created/modified: [list]
Ticket commands that would run: [list]
Git operations that would run: [list]

To execute for real, run the skill without /dso:dryrun.
```
