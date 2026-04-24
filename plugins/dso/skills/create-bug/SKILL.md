---
name: create-bug
description: Guidance for creating well-formatted, evidence-based bug reports using the shared bug report template and ticket CLI.
user-invocable: false
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Create Bug Report

Reference skill for agents creating bug tickets. This skill is a thin workflow wrapper around the shared bug report template — the template is the source of truth for format, rules, and rubrics.

## Prerequisites

Before creating a bug ticket, read the template:

```
${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/bug-report-template.md
```

It defines: title format (`[Component]: [Condition] -> [Observed Result]`), priority rubric (integers 0–4, never "high/medium/low"), Zero Inference Rule (no root-cause speculation, no hindsight, no forced debugging, no low-value tickets), and the six description sections. Treat it as authoritative.

## Workflow

1. **Gather evidence.** Exact error messages, exit codes, commands that triggered the failure, expected vs. actual behavior with a pointer to the contract/rule/skill definition that defines "expected".
2. **Format the description.** Populate template §2 "Incident Overview" (always required). Add §1 (Technical Environment), §3 (Action History), §4 (Chronological Rationalization), §5 (Skills and Workflows), and §6 (Logs) whenever you have real data for them — the heredoc below is a minimum skeleton, not a ceiling.
3. **Create the ticket.** Use the shim — never call plugin scripts directly.
4. **Validate the title post-creation.** The ticket-create script emits a stderr warning when the title pattern is malformed. Catch it and auto-repair.
5. **Confirm** with `ticket show`.

```bash
# Capture stderr to a unique temp file so concurrent callers do not collide.
BUG_CREATE_ERR_FILE=$(mktemp /tmp/bug-create-err.XXXXXX)
BUG_CREATE_OUT=$(.claude/scripts/dso ticket create bug \
  "[Component]: [Condition] -> [Observed Result]" \
  --priority <priority> \
  -d "$(cat <<'DESC'
### 2. Incident Overview

* **Scenario Type:** [User-Flagged Behavior | Sub-Agent Blocker | Deferred Review Nitpick]

#### Expected Behavior

[What should have happened, referencing the contract/rule/skill that defines it.]

#### Actual Behavior

[Raw, factual output. No subjective adjectives.]
DESC
)" 2>"$BUG_CREATE_ERR_FILE")
BUG_CREATE_ERR=$(cat "$BUG_CREATE_ERR_FILE"); rm -f "$BUG_CREATE_ERR_FILE"
BUG_TICKET_ID=$(echo "$BUG_CREATE_OUT" | grep -oE '[0-9a-f]{4}-[0-9a-f]{4}' | head -1)

# Post-creation title gate — the only enforced check.
if echo "$BUG_CREATE_ERR" | grep -q "does not match required pattern"; then
    .claude/scripts/dso ticket edit "$BUG_TICKET_ID" \
        --title="[Component]: [Condition] -> [Observed Result]"
fi

.claude/scripts/dso ticket show "$BUG_TICKET_ID"
```

## CLI_user Tag Policy

Do **not** add `--tags CLI_user` by default. The tag is reserved for bugs a human user explicitly requested during an interactive session. Only the calling agent — the one with direct knowledge that the user asked for the ticket — should add it. Autonomous creations (anti-pattern scans, debug discoveries, sub-agent blockers) omit the tag.

## Consolidation Rule

When multiple Priority 4 (nitpick) findings share the same Component, consolidate into a single cleanup ticket. List each item as a bullet under §2 Actual Behavior and set Scenario Type to "Deferred Review Nitpick".

## Using This Skill

This is guidance, not a behavioral workflow. Agents:

1. Read this skill when they need to create a bug ticket.
2. Consult `skills/shared/prompts/bug-report-template.md` for the full template.
3. Use `.claude/scripts/dso ticket create bug` (the shim) — never call plugin scripts directly.
4. Follow the Zero Inference Rule — report observations, not theories.

Common callers: `/dso:fix-bug` (Step 7.5 anti-pattern scan), `/dso:debug-everything` (diagnostic discoveries), `/dso:sprint` (Phase 5 task failures), `/dso:end-session` (learnings triage), and any agent encountering unexpected behavior.
