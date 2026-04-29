# Shared Bug Report Template

Standalone template for generating objective, evidence-based bug reports. Referenced by `/dso:fix-bug`, `/dso:debug-everything`, and any agent creating bug tickets via `.claude/scripts/dso ticket create bug`. Acts as a "black box recorder" for the system — documents symptoms, not causes.

## Zero Inference Rule

All bug reports MUST pass these constraints before creation:

1. **NO Root Cause Speculation:** Document symptoms, not causes. Never guess *why* a failure occurred.
2. **NO Hindsight Bias:** Logs must reflect raw thought process *as it happened*, without retroactive wisdom of knowing an error occurred or the user flagged it.
3. **NO Forced Debugging:** Do not invent new steps to fix the issue just to fill out the report. Only document actions and workarounds already attempted.
4. **NO Low-Value Tickets:** Do not create bugs for temporary review defenses, arbitrary refactors that don't fix a problem, or changes lacking clear user/system value.

---

## Title Format

Use the exact format: `[Component]: [Condition] -> [Observed Result]`

**[Component]** — Select the most granular identifier available using this strict hierarchy:

1. Specific Tool/Skill (e.g., `GitHubTool`, `/dso:sprint`)
2. File/Directory Path (e.g., `hooks/pre-commit-review-gate.sh`)
3. Logical Workflow (e.g., `DeploymentPipeline`, `MergeToMain`)

**[Condition]** — The action being attempted (e.g., "write_to_disk", "dispatch sub-agent", "validate schema").

**[Observed Result]** — The raw, factual output. No subjective adjectives ("bad", "weird") and no generic nouns ("issue", "error").

**Example:** `FileSystem: write_to_disk -> Permission Denied (EACCES)`

---

## Priority Rubric (0-4)

Select the single integer that matches the impact:

| Priority | Label | Definition |
|----------|-------|------------|
| **0** | Critical | System-wide failure, data loss, or security breach. Total blocker. |
| **1** | High | Major feature broken. Directly blocks the agent's primary mission. No workaround. |
| **2** | Medium | Partial feature failure or significant regression. Inefficient workaround exists. |
| **3** | Low | Minor bug, cosmetic issue, or minor UX friction. |
| **4** | Trivial | Deferred review feedback ("Nitpicks"), request for info, or nice-to-have polish. |

---

## Description Template

Use the sections below. **Required** sections must always be populated. **Optional** sections should be included when the information is available and relevant.

### 1. Technical Environment (Optional)

* **Model ID:** [e.g., claude-opus-4-6]
* **Plugin/Tool Versions:** [e.g., dso plugin v1.2]
* **Active Configs:** [Key environment variables, flags, or configs affecting execution]
* **Context Scope:** [Working directory, repo branch, or specific file path]
* **code_version:** [Full 40-character SHA from `git rev-parse HEAD` at time of filing — used by fix-bug to verify the bug's code is present in the target worktree before investigation begins; full SHA preferred over abbreviated forms to avoid ambiguity in large repos]

### 2. Incident Overview (Required)

* **Scenario Type:** [Choose one: User-Flagged Behavior | Sub-Agent Blocker | Deferred Review Nitpick]

#### Expected Behavior

[Factual statement of what the system/code should have done, based on documented contracts, CLAUDE.md rules, or skill definitions.]

#### Actual Behavior

[Factual statement of what was observed, including specific error codes, exit codes, and log output.]

### 3. Action History and Workarounds (Optional)

* **Steps Taken:**
  * [Action 1: Command/Skill executed]
  * [Action 2: Command/Skill executed]
* **Raw Results:**
  * [Result 1: Exact terminal output or API response]
  * [Result 2: Exact terminal output or API response]
* **Known Workarounds:** [If a temporary fix successfully bypassed the issue, document it here. Otherwise, state "None"]

### 4. Chronological Rationalization (Optional)

Document the agent's internal logic flow *before* the error was fully understood. No hindsight applied.

* [Timestamp/Step 1]: [Raw, original assumption or reasoning for taking the first action]
* [Timestamp/Step 2]: [Raw, original reasoning for subsequent actions]

### 5. Skills and Workflows (Optional)

* **Active Workflow:** [High-level task being executed, e.g., `/dso:sprint` Phase 5]
* **Skills Invoked:** [List of agent capabilities used during the failure]

### 6. Logs (Optional)

Paste relevant log output here. Apply these rules:

* **Truncate at 30,000 characters (30K).** If logs exceed 30K characters, include only the most relevant portion in the description and move the full logs to a ticket comment using `.claude/scripts/dso ticket comment <id> "<overflow content>"`.
* Include only logs directly related to the failure — do not paste entire session transcripts.
* Preserve exact formatting (no summarization, no paraphrasing).

### 7. Additional Details (Optional)

Any other context that does not fit the sections above: screenshots, links to related tickets, reproduction frequency, environment-specific notes.

---

## Special Scenario Rules

### Scenario A: User-Flagged Incorrect Behavior

Ensure the "Chronological Rationalization" meticulously logs the logic that caused the incorrect behavior, and the "Action History and Workarounds" includes the exact commands that led to the user's intervention.

### Scenario B: Sub-Agent Implementation Blocker

Ensure the "Technical Environment" captures the precise state and context scope the sub-agent was handed before it became blocked.

### Scenario C: Deferred Review Feedback (Nitpicks)

* **Consolidation Rule:** If multiple minor review feedback items (Priority 4) share the same [Component], consolidate them into a single "Cleanup" ticket. List each nitpick under the "Actual Behavior" section as bullet points.
* **Tagging:** Select "Deferred Review Nitpick" as the Scenario Type.

---

## CLI Usage

Create a bug ticket using the template:

```bash
.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" \
  -d "$(cat <<'DESC'
### 2. Incident Overview

* **Scenario Type:** [User-Flagged Behavior | Sub-Agent Blocker | Deferred Review Nitpick]

#### Expected Behavior

[What should have happened]

#### Actual Behavior

[What was observed]
DESC
)"
```

**Note:** Only add `--tags CLI_user` when the user explicitly requested the bug ticket during an interactive session. Do not add it for autonomously discovered bugs.
