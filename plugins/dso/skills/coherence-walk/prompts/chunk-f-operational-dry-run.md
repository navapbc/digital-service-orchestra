# Chunk F — operational-dry-run

**Workflow stage:** `operational-dry-run`

The orchestrator prepended `skills/coherence-walk/prompts/verdict-rubric.md` to your prompt before this chunk-specific section. The rubric defines verdict semantics, finding severity, output format, and cite-or-omit discipline. Follow it.

This chunk is structurally different from chunks A–E. The others read static workflow files. You read the **output of a preview script** that the orchestrator ran before dispatching you.

## Input data

The orchestrator ran `scripts/closure-checks-migration-preview.sh` and captured its JSON output. That JSON is appended to your prompt under `### Preview script output` below. Each entry in the JSON array represents one closed `brainstorm:complete`-tagged epic and the counts of items that would be classified `end-state`, `transitional`, or `uncertain` under the new schema if the bulk migration ran today.

The JSON array shape (per item):

```json
{
  "epic_id": "<id>",
  "epic_title": "<title>",
  "items_total": <int>,
  "items_classified_end_state": <int>,
  "items_classified_transitional": <int>,
  "items_classified_uncertain": <int>,
  "sample_transitional_items": ["<text>", "<text>", "<text>"]
}
```

If `closure-checks-migration-preview.sh` failed to run (e.g., no API key, no `brainstorm:complete`-tagged closed epics, script error), the orchestrator passes you the empty array `[]` and a `preview_error` field. In that case, emit `status: "AMBIGUOUS"` with a finding that names the preview-script failure.

## Validation property

The migration prevents future false-positive closures if and only if:

1. **Across the 10 sampled epics, the classifier identifies at least one item per epic on average that would be re-classified as transitional or uncertain.** The point of the migration is to surface items that should not be in `## Success Criteria`. If the classifier finds zero across 10 epics, either the population is already clean (good signal — write PASS but flag low yield as informational) OR the classifier is mis-tuned (bad signal — write FAIL).

2. **The transitional / uncertain items, sampled in `sample_transitional_items`, are plausibly transitional.** Spot-check 2–3 sample items per epic. If they are clearly end-state items being mis-classified as transitional ("the system supports OAuth" → transitional is wrong), that is a FAIL with a finding naming the classifier prompt as the resolution path.

3. **No epic has `items_classified_uncertain` ≥ 50% of `items_total`.** A high uncertain rate means the classifier prompt is under-specified for those items and the bulk migration will escalate everything to the user, defeating the automation goal. >= 50% uncertain in any epic is an important finding.

## Verdict mapping

- All three properties hold → `status: "PASS"`. Cite the per-epic counts in `evidence_citations` using `epic_id` as the file field and `0` as the line field (since this is data, not a file).
- Property 1 fails on the "classifier mis-tuned" interpretation OR property 2 finds clear mis-classifications → `status: "FAIL"` with `severity: "critical"` or `"important"` findings.
- Property 3 fails OR sample items are ambiguous OR preview script returned `preview_error` → `status: "AMBIGUOUS"`.

## Out of scope

Do not evaluate:
- The classifier prompt design itself (that's story ad70's scope)
- The migration script's correctness (that's the Phase 4 cutover)
- API cost (you are read-only on the preview output)
- Anything other than: do the counts and samples support the claim that the migration prevents false-positive closures?

## Output

Emit a single JSON object per `docs/contracts/coherence-walkthrough-chunk-output.md` §1 with `workflow_stage: "operational-dry-run"`. JSON only — no surrounding prose.

---

### Preview script output

The orchestrator appends `closure-checks-migration-preview.sh` JSON output here at dispatch time:

```json
<<<PREVIEW_OUTPUT_PLACEHOLDER>>>
```
