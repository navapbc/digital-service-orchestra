# Contract: coherence-walkthrough chunk output

- Signal Name: coherence-walkthrough-chunk-output
- Status: accepted
- contract_version: 1
- Scope: scripts/coherence-walkthrough.sh ↔ six opus chunks ↔ aggregated-report comment on the gated epic
- Date: 2026-05-20

## Purpose

This document defines the JSON output shape that each of the six opus chunks returns to `scripts/coherence-walkthrough.sh`, the aggregated-report format the orchestrator writes as a ticket comment on the gated epic, and the orchestrator's contract for retry and tech-failure handling. Chunks that disagree on the shape or semantics produce un-aggregatable output and break the Phase 4 cutover gate; this contract is the single source of truth all six chunks and the orchestrator align against.

Consumers:

- `skills/coherence-walk/prompts/verdict-rubric.md` references this contract for the verdict semantics and JSON output shape.
- `skills/coherence-walk/prompts/chunk-*.md` (all six chunk prompts) cite this contract in their "Output" sections.
- `scripts/coherence-walkthrough.sh` parses chunk outputs against this schema and constructs the aggregated report per §2.

Direct consumer: epic a03c-d55e-1393-4f27 Phase 4 cutover gate. Future schema-migration epics that re-use the walkthrough may pass a different `--epic-id` argument; the contract applies regardless of the gated epic ID.

---

## §1. Per-chunk JSON output schema

Each of the six chunks returns one JSON object with the following shape:

```json
{
  "workflow_stage": "brainstorm",
  "status": "PASS",
  "evidence_citations": [
    {"file": "${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md", "line": 142},
    {"file": "${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/verifiable-sc-check.md", "line": 38}
  ],
  "findings": [
    {
      "severity": "minor",
      "description": "Brainstorm dialogue routes transitional SCs to Closure Checks but the refusal copy in skills/brainstorm/phases/approval-gate.md does not cite the canonical litmus test by name.",
      "recommendation": "Add a sentence referencing 'the canonical litmus test' in approval-gate.md so the user can trace the rejection back to the rule."
    }
  ],
  "tech_failure": false
}
```

### Field definitions

| Field | Type | Required | Allowed values | Notes |
|-------|------|----------|----------------|-------|
| `workflow_stage` | string | yes | `"brainstorm"`, `"preplanning"`, `"implementation-plan"`, `"sprint"`, `"commit-and-review"`, `"operational-dry-run"` | Identifies which chunk produced this output. |
| `status` | string | yes | `"PASS"`, `"AMBIGUOUS"`, `"FAIL"` | Verdict semantics in `verdict-rubric.md`. |
| `evidence_citations` | array of `{file, line}` | yes (≥1 when status is PASS or FAIL; ≥0 when AMBIGUOUS) | n/a | File paths must be repo-relative. Line numbers must be positive integers. |
| `findings` | array of `{severity, description, recommendation}` | yes (may be empty when status is PASS) | n/a | See finding shape below. |
| `tech_failure` | bool | no (defaults to `false`) | `true` / `false` | Set to `true` ONLY by the orchestrator when retry exhausts; agents themselves never emit `tech_failure: true`. |

### Finding shape

```json
{
  "severity": "minor",
  "description": "<one-paragraph factual statement>",
  "recommendation": "<concrete action that would resolve the finding>"
}
```

| Field | Allowed values |
|-------|----------------|
| `severity` | `"critical"`, `"important"`, `"minor"` |
| `description` | Free-text. Must cite file:line in `evidence_citations`; no hand-waved claims. |
| `recommendation` | Free-text. One of: spec amendment, prompt fix, explicit defer. |

### Severity → status correspondence

The chunk verdict (`status`) is derived from its findings per `verdict-rubric.md`:

- Any `critical` or `important` finding → `status: "FAIL"`
- Only `minor` findings (or no findings) → `status: "PASS"`
- Verifier-evidence-incomplete or uncertain-citations → `status: "AMBIGUOUS"`

A chunk MUST NOT emit `status: "PASS"` while listing a critical or important finding.

---

## §2. Aggregated-report format

After all six chunks return (with retry handling per §3), the orchestrator writes one aggregated report as a ticket comment on the gated epic. The report has two sections:

### §2.1 Summary table

```
COHERENCE_WALKTHROUGH_REPORT: epic=<epic-id> timestamp=<ISO-8601> overall_verdict=<PASS|BLOCKED>

| Chunk | Workflow Stage         | Status   | tech_failure | Findings (c/i/m) |
|-------|------------------------|----------|--------------|------------------|
| A     | brainstorm             | PASS     | false        | 0/0/1            |
| B     | preplanning            | PASS     | false        | 0/0/0            |
| C     | implementation-plan    | FAIL     | false        | 1/0/2            |
| D     | sprint                 | PASS     | false        | 0/0/0            |
| E     | commit-and-review      | AMBIGUOUS| false        | 0/0/0            |
| F     | operational-dry-run    | PASS     | false        | 0/0/0            |
```

`overall_verdict`:

- `PASS` — all six chunks have `status: "PASS"` AND `tech_failure: false`.
- `BLOCKED` — any chunk has `status: "FAIL"` OR `status: "AMBIGUOUS"` OR `tech_failure: true`.

### §2.2 Per-chunk JSON blocks

After the summary table, the report appends each chunk's full JSON output, fenced as code blocks:

````
### Chunk A — brainstorm
```json
{ ... full JSON output from chunk A ... }
```

### Chunk B — preplanning
```json
{ ... full JSON output from chunk B ... }
```
... (all six chunks)
````

---

## §3. Retry and tech-failure handling

The orchestrator runs each chunk through the following state machine:

1. Dispatch the chunk opus agent.
2. Parse the returned JSON against the schema in §1.
3. If parse succeeds and `status` is a valid value → record the output verbatim. Done.
4. If parse fails (malformed JSON, missing required field, invalid enum value) OR the agent times out → retry the chunk **once** with the same prompt.
5. If the retry succeeds (per step 3) → record the retry output. Done.
6. If the retry also fails → synthesize a `tech_failure` output:

   ```json
   {
     "workflow_stage": "<chunk's workflow_stage>",
     "status": "AMBIGUOUS",
     "evidence_citations": [],
     "findings": [
       {
         "severity": "important",
         "description": "Two consecutive opus dispatches failed to produce a parseable verdict. First failure: <one-line summary>. Second failure: <one-line summary>.",
         "recommendation": "Re-run the walkthrough manually; if tech-failure persists, dispatch this chunk in isolation to diagnose."
       }
     ],
     "tech_failure": true
   }
   ```

A chunk with `tech_failure: true` blocks Phase 4 cutover (it counts as AMBIGUOUS in the overall verdict per §2.1) — human resolution is required before migration.

The orchestrator does NOT auto-retry more than once per chunk. Repeated tech-failure is a signal that something deeper is broken (API outage, agent definition regression) and human attention is needed.

---

## §4. Resolution paths when overall_verdict = BLOCKED

When the aggregated report has `overall_verdict: BLOCKED`, Phase 4 migration is blocked. Three resolution paths (all recorded on the epic ticket):

1. **Spec amendment** — the underlying issue is a real misalignment that the planning artifact MUST encode. Amend the epic spec, then re-run the walkthrough.
2. **Prompt fix** — the underlying issue is that one of the planning workflow files (skill SKILL.md, prompt file, agent file) has incorrect content. Fix the prompt, then re-run the walkthrough.
3. **Explicit defer** — the issue is acknowledged but consciously deferred (e.g., follow-on epic will address). Record a `DEFERRED:` comment on the epic naming the deferral target. The walkthrough re-run is NOT required when this path is chosen — Phase 4 can proceed if all six chunks are deferred or PASS.

The orchestrator does not enforce which path is taken — humans choose. The walkthrough is a gate, not a decision-maker.

---

## §5. Schema versioning policy

This contract is `contract_version: 1`. Future schema changes:

- Adding optional fields → backward-compatible; remains `contract_version: 1`.
- Adding required fields, removing fields, changing enum values, or changing the aggregated-report format → requires `contract_version: 2` and a migration plan for any consumer that pinned `contract_version: 1`.

`contract_version: 1` is retired only via formal version bump to v2 with a documented migration plan. Mirrors the versioned-contract retire policy already used by `end-state-item-validator` (the pluggable validator hook).
