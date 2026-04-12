---
name: create-bug
description: Guidance for creating well-formatted, evidence-based bug reports using the shared bug report template and ticket CLI.
user-invocable: false
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Create Bug Report

Reference skill for agents creating bug tickets. Ensures consistent, objective, evidence-based bug reports across all workflows.

## Prerequisites

Before creating a bug ticket, read the shared bug report template:

```
${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/bug-report-template.md
```

That template defines the full structure: title format, Zero Inference Rule, priority rubric, and description sections. This skill summarizes the workflow; the template is the source of truth.

## Quick Reference

### CLI Command

```bash
.claude/scripts/dso ticket create bug "<title>" -p <priority> -d "<description>"
```

### Title Format

Use the exact format from the template:

```
[Component]: [Condition] -> [Observed Result]
```

- **Component**: Most granular identifier (tool/skill > file path > logical workflow)
- **Condition**: Action being attempted
- **Observed Result**: Raw, factual output (no subjective adjectives like "bad" or "weird")

**Example:** `FileSystem: write_to_disk -> Permission Denied (EACCES)`

### Priority (0-4)

| Priority | When to use |
|----------|-------------|
| 0 | System-wide failure, data loss, security breach |
| 1 | Major feature broken, no workaround |
| 2 | Partial failure, inefficient workaround exists |
| 3 | Minor bug, cosmetic issue |
| 4 | Deferred nitpick, nice-to-have |

Never use "high", "medium", or "low" -- always use the integer 0-4.

## Zero Inference Rule

All bug reports MUST comply with these constraints (enforced by the template):

1. **NO Root Cause Speculation** -- document symptoms, not causes
2. **NO Hindsight Bias** -- logs reflect raw thought process as it happened
3. **NO Forced Debugging** -- only document actions already attempted
4. **NO Low-Value Tickets** -- no bugs for temporary review defenses, arbitrary refactors, or changes lacking clear value

## Creating a Bug Ticket

### Step 1: Gather Evidence

Collect factual observations before writing the report:
- Exact error messages, exit codes, and log output
- Commands that triggered the failure
- Expected vs. actual behavior (referencing contracts, rules, or skill definitions)

### Step 2: Format the Description

Use the template's required and optional sections. At minimum, include:

```
### 2. Incident Overview

* **Scenario Type:** [User-Flagged Behavior | Sub-Agent Blocker | Deferred Review Nitpick]

#### Expected Behavior

[What should have happened]

#### Actual Behavior

[What was observed]
```

Include optional sections (Technical Environment, Action History, Logs) when the information is available and relevant.

### Step 3: Create the Ticket

**TITLE FORMAT GATE — do not proceed until this passes:** Verify your title matches `[Component]: [Condition] -> [Observed Result]` exactly. Check:
- Starts with `[Component]` in square brackets (e.g., `[ticket-transition.sh]`, `[sprint Phase 2]`, `[figma_node_mapper.py]`)
- Followed by `: [Condition]` — the action attempted
- Followed by ` -> [Observed Result]` — the raw factual output
- Bad: `"figma_node_mapper.py: effects not mapped"` (missing brackets, no `->`)
- Good: `"[figma_node_mapper.py]: _map_single_node() called -> effects field absent from output"`

```bash
# Capture both stdout and stderr to enable post-creation title validation
BUG_CREATE_OUT=$(.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" \
  -p <priority> \
  -d "$(cat <<'DESC'
### 2. Incident Overview

* **Scenario Type:** [User-Flagged Behavior | Sub-Agent Blocker | Deferred Review Nitpick]

#### Expected Behavior

[What should have happened]

#### Actual Behavior

[What was observed]
DESC
)" 2>/tmp/bug_create_stderr.tmp)
BUG_CREATE_ERR=$(cat /tmp/bug_create_stderr.tmp); rm -f /tmp/bug_create_stderr.tmp
BUG_TICKET_ID=$(echo "$BUG_CREATE_OUT" | grep -oE '[0-9a-f]{4}-[0-9a-f]{4}' | head -1)
```

### Step 4: Validate and Fix Title

**Post-creation title fix (mandatory):** Check stderr for the title format warning and fix immediately if present:

```bash
if echo "$BUG_CREATE_ERR" | grep -q "does not match recommended pattern"; then
    # Fix the title NOW — do not skip this step
    .claude/scripts/dso ticket edit "$BUG_TICKET_ID" --title="[Component]: [Condition] -> [Observed Result]"
fi
```

Then confirm the ticket was created correctly:

```bash
.claude/scripts/dso ticket show "$BUG_TICKET_ID"
```

Confirm the title starts with `[Component]:` and contains `->`. If it does not, edit it before proceeding.

## CLI_user Tag Policy

Do **not** add `--tags CLI_user` by default. The `CLI_user` tag is reserved for bugs explicitly requested by a human user during an interactive session. Only the calling agent -- the one with direct knowledge that the user explicitly asked for the bug ticket -- should add `--tags CLI_user`. If you are creating a bug autonomously (anti-pattern scan, debug discovery, sub-agent blocker), omit the tag entirely.

## Consolidation Rule

When multiple Priority 4 (nitpick) findings share the same Component, consolidate them into a single cleanup ticket. List each item as a bullet under the Actual Behavior section. Select "Deferred Review Nitpick" as the Scenario Type.

## Using This Skill

This is a guidance skill, not a behavioral workflow. Agents should:

1. Read this skill's guidance when they need to create a bug ticket
2. Consult `skills/shared/prompts/bug-report-template.md` for the full template
3. Use `.claude/scripts/dso ticket create bug` (the shim) for ticket creation -- never call plugin scripts directly
4. Follow the Zero Inference Rule strictly -- report what you observed, not what you think caused it

Workflows that commonly create bugs: `/dso:fix-bug` (Step 7.5 anti-pattern scan), `/dso:debug-everything` (diagnostic discoveries), `/dso:sprint` (Phase 5 task failures), and any agent encountering unexpected behavior during execution.
