# Investigation Contracts (loaded by /dso:fix-bug investigation sub-agents and orchestrator on escalation re-entry)

Reference material consumed by investigation sub-agents (RESULT report schema), the discovery-file lifecycle (path, fields, readers/writers), and sub-agent context detection (escalation re-entry, tier degradation, COMPLEX_ESCALATION report format).

## Investigation RESULT Report Schema

All investigation tiers produce a RESULT report with this schema. Higher tiers include additional fields.

```
ROOT_CAUSE: <one sentence describing the identified root cause>
confidence: high | medium | low
proposed_fixes:
  - description: <what the fix does>
    risk: high | medium | low
    degrades_functionality: true | false
    rationale: <why this fix addresses the root cause>
hypothesis_tests:
  - hypothesis: <what was tested>
    test: <the test command>
    observed: <what actually happened>
    verdict: confirmed | disproved | inconclusive
prior_attempts:
  - commit: <sha>
    description: <what was tried>
    outcome: <why it failed>
```

INTERMEDIATE and above add:
```
alternative_fixes: [...]  # at least 2 total proposals
tradeoffs_considered: <analysis of approach tradeoffs>
recommendation: <which fix and why>
```

ADVANCED adds:
```
convergence_score: <how many agents agreed on this root cause>
fishbone_categories:
  code_logic: <findings>
  state: <findings>
  configuration: <findings>
  dependencies: <findings>
  environment: <findings>
  data: <findings>
```

## Discovery File Protocol

Investigation findings are persisted to a discovery file for passing context between phases (investigation to fix, or across escalation tiers).

- **Path convention**: `/tmp/fix-bug-discovery-<ticket-id>.json`
- **Required fields**:
  - `root_cause` — one-sentence root cause description
  - `confidence` — high, medium, or low
  - `proposed_fixes` — array of fix proposals (each with description, risk, degrades_functionality)
  - `hypothesis_tests` — array of hypothesis test results
  - `prior_fix_attempts` — array of previous fix attempts (empty if none)
- **Written by**: investigation sub-agents (Phase C Step 1) and hypothesis testing (Phase C Step 2)
- **Read by**: fix approval (Phase D Step 1), fix implementation (Phase E Step 3), and escalation re-entry (Phase C Step 1 on retry)
- **Lifecycle**: created at first investigation, updated on escalation, deleted after successful commit (Phase H Step 1)

When escalating to the next tier, the discovery file from the previous tier is included in the new sub-agent's context so it does not repeat work.

## Sub-Agent Context Detection

When `/dso:fix-bug` is invoked inside a larger workflow (e.g., from `/dso:sprint` or `/dso:debug-everything`), it runs as a sub-agent. Sub-agent context affects which investigation tiers are available.

### Re-entry from COMPLEX_ESCALATION

When the invocation prompt contains a `### COMPLEX_ESCALATION Context` block (emitted by `/dso:debug-everything` Phase H Step 8 during orchestrator-level re-dispatch), skip Steps 1-3 and proceed directly to Phase D Step 1 (Fix Approval):

1. Parse the `investigation_findings` from the `COMPLEX_ESCALATION Context` block
2. Write the findings to the discovery file (`/tmp/fix-bug-discovery-<bug-id>.json`) with the parsed root cause, confidence, and proposed fixes
3. Skip to Phase D Step 1 (Fix Approval) — the prior investigation is pre-loaded and does not need to be repeated

This avoids re-running classification and investigation work that was already completed by the sub-agent before escalation.

### Detection Methods

**Primary — Agent tool availability**: Before dispatching investigation sub-agents, check whether the Agent tool is available in the current context. If the Agent tool is not available, the skill is running as a sub-agent (dispatched via the Task tool) and must surface findings to the caller instead of escalating.

**Fallback — orchestrator signal**: The orchestrator may also set `You are running as a sub-agent` in the dispatch prompt. When present, this confirms sub-agent context.

### Behavior in Sub-Agent Context

Behavior is owned by the relevant phases — see ticket lifecycle (Phase A Step 2), COMPLEX_ESCALATION report on complex fixes (Phase D Step 2), commit and close / FIX_RESULT report (Phase H Step 1). Investigation tier degradation: BASIC and INTERMEDIATE work fully nested; ADVANCED and ESCALATED require Agent tool availability — if unavailable, return a `COMPLEX_ESCALATION` report (see below) so the calling orchestrator can re-dispatch with full authority.

### Escalation Report Format

When running as a sub-agent and ADVANCED or ESCALATED investigation is needed but cannot be performed due to Agent tool unavailability or other blocking conditions, return a `COMPLEX_ESCALATION` report to the calling orchestrator. This uses the same format as Phase D Step 2's COMPLEX_ESCALATION — one unified format for all escalation paths:

```
COMPLEX_ESCALATION: true
escalation_type: advanced_needed | escalated_needed | terminal
bug_id: <ticket-id>
investigation_tier_needed: ADVANCED | ESCALATED
investigation_findings: <summary of root cause candidates, confidence, evidence, and hypothesis test results from investigation>
escalation_reason: <why escalation is needed and cannot proceed autonomously>
```

The calling orchestrator detects `COMPLEX_ESCALATION: true` and parses the same fields regardless of whether the escalation originated from complexity evaluation (Phase D Step 2) or tier unavailability (this section). See `/dso:debug-everything` Phase H Step 8 for the orchestrator's handling of this signal.
