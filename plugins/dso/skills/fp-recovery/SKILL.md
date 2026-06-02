---
name: fp-recovery
description: Manual review escalation when CI llm-review blocks a PR on a finding that looks like a false positive. Dispatches dso:code-reviewer-standard at opus tier on the PR's diff, parses the result, and emits a force-merge clearance when zero critical/important/fragile findings remain. Use ONLY when CI llm-review has failed on a suspect FP; not for routine PR shipping. Trigger phrases include 'force merge this PR', 'the CI review is wrong', 'false positive from llm-review', 'manual review override', 'FP recovery'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# FP Recovery — Manual Review Escalation

Shallow entry point for the FP-recovery workflow. Loads and executes `${CLAUDE_PLUGIN_ROOT}/docs/workflows/FP-RECOVERY-WORKFLOW.md` inline.

## When to invoke

CI `llm-review` (ci.yml) has reported `failure` AND the engineer believes the blocking finding is a false positive. All other required checks must pass (or be filed as known intermittent bugs). See FP-RECOVERY-WORKFLOW.md "When to invoke" for the full precondition list.

**Eligible finding types** — FP-recovery may be invoked for findings of any of these types when the engineer believes the finding is a false positive:
- Code-level findings (logic, security, correctness, style)
- DESIGN.md lint findings — violations flagged by the `check-design-lint.sh` hook or equivalent design-doc linter (e.g., missing required sections, disallowed heading format, broken cross-references to ticket IDs). These are eligible when the engineer can demonstrate the design document is structurally correct and the linter rule is misapplied for the specific context.

**Common false-positive patterns for DESIGN.md lint findings:**
- The linter flags a missing required section that is intentionally omitted because it is not applicable to the change type (e.g., no "Data Model" section for a UI-only change).
- A ticket ID cross-reference is flagged as broken, but the ticket exists and the ID format is correct (linter regex mismatch).
- The linter rejects a heading because of an extra trailing space or Unicode em-dash that is visually indistinguishable from a standard ASCII hyphen.
- A newly added DESIGN.md section is flagged as unknown because the linter's allowed-section list has not been updated.

**Finding format for DESIGN.md lint findings** — when invoking FP-recovery for a DESIGN.md lint finding, the engineer must supply:
1. The exact linter rule name or error message (copy from CI log).
2. The specific line(s) in `DESIGN.md` that triggered the finding.
3. A concise rationale explaining why the finding is a false positive (not just "it looks fine").

**OVER_BOUND PRs are not eligible for FP-recovery.** If the PR's CI output contains an `OVER_BOUND:` marker (emitted when the PR exceeds the `max_files × max_calls` hard upper bound), reject immediately with:
`OVER_BOUND PRs are not eligible for FP-recovery — these require admin attention (chunking budget exceeded, not a false-positive).`
The CI reviewer never ran on an OVER_BOUND PR; there is no LLM finding to adjudicate. These PRs require admin review or must be split into smaller chunks. Use `${CLAUDE_PLUGIN_ROOT}/scripts/check-fp-recovery-eligibility.sh` (env: `DSO_CI_LOG=<path>`) to perform this gate programmatically.

**This is an escape valve, not a routine path.** Routine PRs ship through `/dso:commit` + `merge-to-main.sh`. Invoke this skill only when the CI reviewer has produced a clearly-wrong blocking finding.

## What this skill does NOT do

- Does NOT skip review — it dispatches a real `dso:code-reviewer-standard` at opus tier on the PR diff.
- Does NOT merge — the autonomous agent runs as a non-bypass identity (`current_user_can_bypass: never`) and cannot bypass branch protection. It emits a clearance verdict + a **web-UI merge link**; a human (the named bypass actor) performs the override via the GitHub web UI.
- Does NOT lower the merge bar — every bypass through this path has a real reviewer review behind it AND requires all other required checks green.
- Does NOT apply to test failures (fix those normally) or intermittent CI failures (re-push / wait).

## Usage

```bash
/dso:fp-recovery <pr-number>
```

Or with the PR number derived from the current branch:

```bash
/dso:fp-recovery
```

## Instructions

**IMPORTANT**: Do NOT call the Skill tool again or re-invoke `/dso:fp-recovery` recursively. Instead:

1. Read `${CLAUDE_PLUGIN_ROOT}/docs/workflows/FP-RECOVERY-WORKFLOW.md` now.
2. Execute its steps in order — starting from Step 0 (OVER_BOUND pre-check), then Step 1 (Capture the PR diff).
3. Follow the verdict criteria in Step 4 strictly: only clear the force-merge when ALL four criteria hold (zero critical, zero important, zero fragile, ≥5 tool calls and ≥30s runtime on the manual review dispatch). The work-proxy thresholds were lowered from the original 10/60s after observing false rejections on legitimately concise reviews — see FP-RECOVERY-WORKFLOW.md Step 2/Step 4 commentary for the calibration rationale.
4. If the manual review produces critical or important findings, **abort** and surface those findings to the user. Do NOT clear the bypass.
5. If clearance is reached, follow Step 5: first confirm every OTHER required check is green (`gh pr checks <PR>` — only `llm-review` may be non-green), then emit the **web-UI merge link** + the required annotation template and hand them to the human as your final action. Delivering that link + annotation IS the successful end state of FP-recovery: the named bypass actor completes the merge via the web UI, and the workflow concludes with that human merge. Your deliverable is the verified clearance + the handoff package — produce it, present it, and stop.

The workflow file is the complete specification. Every step is mandatory — including the "all other required checks green" gate (Step 5a), the auditable annotation, and the PR label per Step 6.
