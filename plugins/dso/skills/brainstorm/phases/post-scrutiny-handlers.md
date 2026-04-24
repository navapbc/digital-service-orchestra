# Post-Scrutiny Handlers

These handlers run **after** the epic scrutiny pipeline returns (Step 3 fidelity review complete). They process the pipeline's output before the approval gate. Skipped in enrich-in-place and depth-capped follow-on stub paths, because those paths do not invoke the scrutiny pipeline.

Execution order:

1. FEASIBILITY_GAP Handler (branches back to Phase 1 or escalates)
2. Research Findings Persistence
3. SC Gap Check
4. Step 2.28 (Relates-to AC Injection — see `cross-epic-handlers.md`)

---

## FEASIBILITY_GAP Handler

After the scrutiny pipeline returns, check whether the epic spec contains a `## FEASIBILITY_GAP` section (annotated by the pipeline's Step 4 when the feasibility reviewer reports any score below 3).

**If FEASIBILITY_GAP is present:**

1. Read `brainstorm.max_feasibility_cycles` from `dso-config.conf` (default: 2 when absent).
2. Initialize or increment `feasibility_cycle_count` (starts at 0, incremented on each re-entry).
3. **Spike check (run before deciding whether to re-enter Phase 1)**: Read the `## FEASIBILITY_GAP` section. If the feasibility reviewer's finding includes a recommendation to run a spike, proof-of-concept, or validation step to resolve an integration assumption:
   - **If the spike is executable within this brainstorm session** (e.g., a codebase grep, a targeted CLI `--help` command, a WebSearch, or a lightweight API endpoint check can answer the question): Execute the spike now. Record the result. If the spike resolves the gap (confirms feasibility or disproves the assumption), remove the `## FEASIBILITY_GAP` annotation and update the spec accordingly. If the spike confirms the assumption is unresolvable, proceed to step 5 (escalate to user).
   - **If the spike is NOT executable within this brainstorm session** (e.g., requires a running service, credentials not available, or multi-day proof-of-concept): Do NOT continue to the approval gate. Escalate immediately: present the unresolved spike recommendation to the user with the exact feasibility reviewer finding, and ask whether to (a) abort and create a spike ticket first, (b) proceed with the gap explicitly annotated as a prerequisite in the epic spec, or (c) manually adjust the approach to eliminate the dependency. Log: `"FEASIBILITY_GAP spike recommendation detected — escalating before approval gate."`
4. **If `feasibility_cycle_count < max_feasibility_cycles` AND no spike recommendation was present (or spike was resolved in step 3)**: Re-enter Phase 1 (understanding loop) with the gap context as seeding material. Log: `"FEASIBILITY_GAP detected — re-entering Phase 1 understanding loop (cycle {feasibility_cycle_count}/{max_feasibility_cycles})."` After the user provides additional context or clarification, re-run the scrutiny pipeline and check again.
5. **If `feasibility_cycle_count >= max_feasibility_cycles`**: Escalate to the user. Present the unresolved gap and ask whether to proceed with the gap noted, abort, or manually adjust the spec. Log: `"FEASIBILITY_GAP unresolved after {max_feasibility_cycles} cycles — escalating to user."`
6. Expose `feasibility_cycle_count` as a named state variable for the Planning-Intelligence Log.

**If FEASIBILITY_GAP is NOT present:** Continue to Research Findings Persistence below.

---

## Research Findings Persistence

After the feasibility-reviewer sub-agent returns (regardless of FEASIBILITY_GAP outcome), persist its capability/status findings as a structured ticket comment on the epic so that downstream agents (preplanning, implementation-plan, sprint) can consume them without re-running web research.

**Skip this step entirely** when no feasibility-reviewer output exists for this brainstorm session (e.g., scrutiny pipeline did not dispatch the reviewer because no integration signals were detected).

**Procedure:**

1. From the feasibility-reviewer output, extract each (capability, status) pair the reviewer evaluated. Map each pair to one researchFindings entry with these fields:
   - `capability` (string): the integration/dependency/capability the reviewer evaluated
   - `status` (enum): one of `verified`, `partially_verified`, `unverified`, `contradicted`
   - `source` (string): the URL or reference the reviewer cited (use `"reviewer:internal"` when the reviewer relied solely on codebase evidence)
   - `skill_name` (string): always `"brainstorm"`
   - `timestamp` (string): ISO 8601 UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`)

2. Assemble the entries into a single JSON array.

3. Write the array as a ticket comment on the epic using the `RESEARCH_FINDINGS:` prefix:

   ```bash
   .claude/scripts/dso ticket comment <epic-id> "RESEARCH_FINDINGS: <JSON>"
   ```

   Example payload:
   ```json
   [
     {"capability": "Figma REST API node export", "status": "verified", "source": "https://www.figma.com/developers/api#get-files-endpoint", "skill_name": "brainstorm", "timestamp": "2026-04-19T18:30:00Z"},
     {"capability": "Concurrent worktree merge safety", "status": "partially_verified", "source": "reviewer:internal", "skill_name": "brainstorm", "timestamp": "2026-04-19T18:30:00Z"}
   ]
   ```

4. Continue to the SC Gap Check below.

---

## SC Gap Check

After the scrutiny pipeline completes (with no unresolved FEASIBILITY_GAP), inspect the surviving scenario set for Success Criteria coverage gaps. A coverage gap exists when a scenario describes a user outcome that is not explicitly addressed by any current SC.

**Procedure:**

1. Re-read the current SCs and the Scenario Analysis section of the epic spec.
2. For each surviving scenario, check whether at least one SC covers the scenario's core user outcome (what the user achieves, not how).
3. **If no gaps found:** Proceed to Step 2.28 (Relates-to AC Injection).
4. **If gaps found:** For each gap, draft a revised or new SC that addresses the uncovered outcome. Then present the proposed SC revisions to the user for re-approval via `AskUserQuestion`:

   > "Scenario analysis identified the following SC gaps: [list gaps with proposed SC revisions]. Do you want to (a) Accept the revised SCs and continue, (b) Modify the proposed revisions, or (c) Skip SC revision and continue with the original SCs?"

   - **(a) Accept:** Apply the revised SCs to the epic spec (update the `## Success Criteria` section via `ticket edit --description`). Then proceed to Step 2.28.
   - **(b) Modify:** Incorporate user changes, present again.
   - **(c) Skip:** Log `"SC gap check: user opted to skip revision."` and proceed to Step 2.28 with original SCs.
