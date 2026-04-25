# COMPLEX_ESCALATION Handler (Phase H Step 8)

Loaded only when one or more Phase G sub-agent results contain a `COMPLEX_ESCALATION: true` signal (rare — emitted by fix-bug Step 4.5 post-investigation when classification finds the bug too complex for solo fix). Skipped otherwise.

## Detection

Scan each sub-agent result for `COMPLEX_ESCALATION: true`.

## Parse fields (per fix-bug Step 4.5 schema)

- `escalation_type`: `COMPLEX` (fix scope too large for single bug fix track).
- `bug_id`: ticket ID being escalated.
- `investigation_tier_needed`: `orchestrator-level re-dispatch`.
- `investigation_findings`: summary of root-cause candidates, confidence, evidence.
- `escalation_reason`: why fix is COMPLEX (e.g., cross-system refactor, multiple subsystems affected).

## Non-interactive mode

Apply Non-Interactive Deferral Protocol with `gate_name=complex_escalation`. Do not invoke `/dso:fix-bug` at orchestrator level — defer the bug. Add to `COMPLEX_BUGS` list for session summary. Continue to next bug.

## Interactive mode — re-dispatch at orchestrator level

Do NOT use a sub-agent for the re-dispatch — invoke `/dso:fix-bug` directly from the orchestrator.

1. Annotate the bug ticket with investigation findings:
   ```bash
   .claude/scripts/dso ticket comment <bug-id> "fix-bug escalation: COMPLEX — <escalation_reason>. Investigation found: <investigation_findings>. Requires <investigation_tier_needed> orchestrator-level re-dispatch."
   ```

2. Invoke `/dso:fix-bug` directly (not as a Task sub-agent), passing investigation findings as pre-loaded context so the orchestrator-level fix-bug can skip re-investigation:
   ```
   /dso:fix-bug <bug-id>

   ### COMPLEX_ESCALATION Context (pre-loaded — skip to Step 4)
   escalation_type: COMPLEX
   bug_id: <bug-id>
   investigation_findings: <investigation_findings>
   escalation_reason: <escalation_reason>
   ```

   When fix-bug detects `COMPLEX_ESCALATION Context` in its invocation prompt, it writes `investigation_findings` to the discovery file (`/tmp/fix-bug-discovery-<bug-id>.json`) and skips directly to Step 4 (Fix Approval) with prior investigation as pre-loaded context.

3. Track all complex-escalated bugs in `COMPLEX_BUGS` list (entries: `{bug_id, escalation_reason, investigation_findings}`) for inclusion in the session summary.
