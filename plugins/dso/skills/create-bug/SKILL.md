---
name: create-bug
description: Use when an agent or user needs to file a bug, report an issue, create a defect ticket, or capture a sub-agent blocker. Creates well-formatted, evidence-based bug tickets by collecting reproduction steps, expected vs. actual behavior, environment details, and logs, then writing the ticket via the ticket CLI using the shared bug report template. Trigger phrases include 'file a bug', 'report an issue', 'create a bug', 'open a ticket', 'log a defect', 'submit a bug report'.
user-invocable: true
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

   **Split-from-umbrella filings:** When Scenario Type is `split-from-umbrella` (i.e., this bug is filed as a result of a cluster-investigation split), the Actual Behavior section MUST include one of:
   - `attribution_basis: evidenced — <CI run URL, failing test name + run, or commit SHA specific to this file/component>`
   - `attribution_basis: speculative — <rationale for why the symptom is suspected; no per-file CI evidence exists>`

   A bug with `attribution_basis: speculative` MUST NOT be scored or investigated at BASIC tier or above until the user explicitly confirms the symptom was observed. Filing without either annotation violates the Zero Inference Rule — symptom-claims inherited from an umbrella title alone are not evidence of a distinct defect.
2. **Format the description.** Populate template §2 "Incident Overview" (always required). Add §1 (Technical Environment), §3 (Action History), §4 (Chronological Rationalization), §5 (Skills and Workflows), and §6 (Logs) whenever you have real data for them — the heredoc below is a minimum skeleton, not a ceiling.
3. **Create the ticket.** Use the shim — never call plugin scripts directly.
4. **Validate the title post-creation.** The ticket-create script emits a stderr warning when the title pattern is malformed. Catch it and auto-repair.
5. **Confirm** with `ticket show`.

**Step 3a — Determine `detected_by` channel (CLI_user sessions only).**

If `CLI_user` will be added (i.e., a human is directly filing this bug in the current interactive session), you **must** ask the user which channel detected the bug before creating the ticket:

```
AskUserQuestion: "Which channel detected this bug?"
Options:
  a) tests             — caught by automated tests / CI
  b) review-llm        — flagged during an LLM code review
  c) review-human      — flagged during a human code review
  d) production        — observed in production
  e) user-report       — reported by an end user
  f) internal-dogfood  — found during internal dogfooding
  g) other             — none of the above
```

Pass the chosen value as `--tags detected_by:<channel>` together with `--tags CLI_user` on the create command (e.g., `--tags CLI_user --tags detected_by:tests`).

**Sub-agent / autonomous callers**: SKIP this prompt entirely. Instead, run `infer-detected-by.sh` (which reads `DSO_FILING_CONTEXT`) to obtain the channel value and pass it as `--tags detected_by:<channel>`. Do **not** add `--tags CLI_user` for autonomous creations.

```bash
# Capture stderr to a unique temp file so concurrent callers do not collide.
BUG_CREATE_ERR_FILE=$(mktemp /tmp/bug-create-err.XXXXXX)
BUG_CREATE_OUT=$(.claude/scripts/dso ticket create bug \
  "[Component]: [Condition] -> [Observed Result]" \
  --priority <priority> \
  -d "$(cat <<'DESC'
### 1. Technical Environment

* **code_version:** [40-char SHA from `git rev-parse HEAD` at time of filing]

### 2. Incident Overview

* **Scenario Type:** [User-Flagged Behavior | Sub-Agent Blocker | Deferred Review Nitpick]

#### Expected Behavior

[What should have happened, referencing the contract/rule/skill that defines it.]

#### Actual Behavior

[Raw, factual output. No subjective adjectives.]
DESC
)" 2>"$BUG_CREATE_ERR_FILE")
BUG_CREATE_ERR=$(cat "$BUG_CREATE_ERR_FILE"); rm -f "$BUG_CREATE_ERR_FILE"
BUG_TICKET_ID=$(echo "$BUG_CREATE_OUT" | tail -1)

# Post-creation title gate — the only enforced check.
if echo "$BUG_CREATE_ERR" | grep -q "does not match required pattern"; then
    .claude/scripts/dso ticket edit "$BUG_TICKET_ID" \
        --title="[Component]: [Condition] -> [Observed Result]"
fi

.claude/scripts/dso ticket show "$BUG_TICKET_ID"
```

## CLI_user Tag Policy

**When to add**: When a human user has directly and explicitly requested this bug be created in the current interactive session — e.g., "Create a bug for X", "File a ticket about Y", "Log this as a bug" — add `--tags CLI_user` to the create command. The calling agent (the one with direct knowledge of the user's request) is responsible for adding the tag; sub-agents that receive a task description but were not directly prompted by the user omit it.

**When to omit**: Autonomous creations — anti-pattern scans, debug discoveries, sub-agent blockers, error-pattern triage, end-session learnings — do **not** add `--tags CLI_user` even if the broader session was initiated by the user. The tag signals user-directed intent, not user-initiated sessions.

**Downstream effect**: CLI_user-tagged bugs skip the intent-search gate in `/dso:fix-bug` Phase B Step 1, since user-reported bugs have known intent. Missing the tag causes unnecessary intent-search dispatch on every user-reported bug.

## Parent Linkage Policy

**Default**: file bugs at the top level (no `--parent`). A bug is `--parent <epic-id>` only when its resolution is required for the epic's success criteria — i.e., the epic's `## Closure Checks` cannot be verified until the bug is fixed.

**Anti-pattern to avoid (bug 7f23-1a14)**: when filing a bug discovered *during* a sprint, debug-everything, or fix-bug session, the active epic ID is the most salient identifier in context, and the reflexive instinct is to pass `--parent <epic-id>` so the bug is "easy to find later." This is wrong: epic-children are work that belongs to the epic, not discoveries made while working on the epic. Sprint-tooling bugs, plugin-infrastructure bugs, lint/test failures unrelated to the epic, and any cross-cutting concerns are **top-level tickets** — they pollute the epic's child list and confuse preplanning's reconciliation phase, completion-verifier's epic closure, and ticket-CLI consumers (`deps`, `next-batch`, `list-descendants`).

**Decision rule**: pass `--parent <epic-id>` only if you can name the epic's success criterion that the bug blocks. If you cannot, file without `--parent`.

**Recovery**: if a bug has already been mis-parented to an unrelated epic, detach it with `.claude/scripts/dso ticket edit <bug-id> --parent=null` — the literal string `null` is the detach sentinel. Empty values (`--parent=`) are rejected to prevent accidental detach from a shell mishap.

## detected_by Field

Every bug ticket must carry a `detected_by:<channel>` tag that records how the bug was found. The allowed values (must match the `ALLOWED` array in `${CLAUDE_PLUGIN_ROOT}/scripts/infer-detected-by.sh`) are:

| Value | Meaning |
|-------|---------|
| `tests` | Caught by automated tests or CI |
| `review-llm` | Flagged during an LLM code review |
| `review-human` | Flagged during a human code review |
| `production` | Observed in production |
| `user-report` | Reported by an end user |
| `internal-dogfood` | Found during internal dogfooding |
| `other` | None of the above / unknown |

**Interactive (CLI_user) sessions**: The LLM asks the user via `AskUserQuestion` (see Step 3a above) and passes the chosen value as `--tags detected_by:<channel>`.

**Autonomous / sub-agent sessions**: Run `${CLAUDE_PLUGIN_ROOT}/scripts/infer-detected-by.sh` (reads `DSO_FILING_CONTEXT`) to obtain the channel value automatically; no user prompt is issued.

## Consolidation Rule

When multiple Priority 4 (nitpick) findings share the same Component, consolidate into a single cleanup ticket. List each item as a bullet under §2 Actual Behavior and set Scenario Type to "Deferred Review Nitpick".

## Common callers

`/dso:fix-bug` (Phase G Step 1 anti-pattern scan), `/dso:debug-everything` (diagnostic discoveries), `/dso:sprint` (Phase F task failures), `/dso:end-session` (learnings triage), and any agent encountering unexpected behavior.
