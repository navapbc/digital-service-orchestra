# Verdict rubric: coherence walkthrough chunks

You are one of six opus-tier reviewers dispatched by `scripts/coherence-walkthrough.sh` to gate Phase 4 of epic a03c-d55e-1393-4f27 (Closure Checks schema migration). Your output is consumed by the orchestrator and aggregated into a report attached to the gated epic.

This rubric file is shared across all six chunks. Your chunk-specific prompt is appended after this rubric and tells you which workflow surface to inspect, what validation property to apply, and which files to read.

## The question you are answering

Each chunk asks one question of a different planning-workflow surface: **"does this workflow correctly handle the SC-vs-Closure-Checks distinction now that the epic has shipped its template, validator hook, and verifier refactor?"** Your job is to read the workflow files cited in your chunk prompt and produce a verdict.

## What you are NOT answering

You are not reviewing code quality. You are not evaluating implementation correctness. You are not running tests. You are not asking whether the planning artifacts are well-designed in general. You are answering only the narrow SC-vs-Closure-Checks distinction question your chunk prompt names.

If you find unrelated issues, do not include them. Findings outside the chunk's validation property are out of scope.

## Verdict semantics

Each chunk emits exactly one of three verdicts:

### PASS
The workflow surface handles the SC-vs-Closure-Checks distinction correctly. You have positive evidence (specific file:line citations) that the validation property holds. There may be minor findings (cosmetic, low-stakes documentation gaps) but no important or critical finding.

A PASS chunk has:
- `status: "PASS"`
- At least one citation in `evidence_citations` showing where the workflow enforces the distinction
- Zero critical and zero important findings (may have minor findings)

### AMBIGUOUS
You cannot conclusively determine whether the workflow handles the distinction. Possible causes:
- The relevant code path exists but is missing concrete examples or canonical-litmus-test references that would make the behavior verifiable
- The workflow has dual code paths and you cannot determine which one runs in practice
- File contents are partially out-of-date with the new schema (some sections updated, others not)
- The validation property is conceptually unclear in the workflow file itself

An AMBIGUOUS chunk has:
- `status: "AMBIGUOUS"`
- Findings explaining what is unclear and what would resolve the ambiguity
- May have zero, one, or many citations

### FAIL
The workflow surface conflates SC and Closure Checks in at least one identifiable place, or has a code path that would produce a wrong outcome under the new schema. You can name the specific file:line where the conflation lives.

A FAIL chunk has:
- `status: "FAIL"`
- At least one citation pointing to the conflation site
- At least one finding with severity `critical` or `important` describing the conflation

## Finding severity

- **critical**: The workflow will produce a wrong outcome at runtime under the new schema (e.g., the completion verifier will pass an epic that has unresolved Closure Checks; brainstorm will refuse a valid end-state SC).
- **important**: The workflow has a real gap that will surface as a bug when exercised, but not necessarily a wrong outcome on every run (e.g., refusal copy doesn't cite the canonical litmus test, so users will not know why the rejection happened).
- **minor**: Documentation drift, cosmetic gap, missing optional reference. The workflow runs correctly but the artifact could be clearer.

## Output format

Your output is a single JSON object conforming to `docs/contracts/coherence-walkthrough-chunk-output.md` §1. Required fields: `workflow_stage`, `status`, `evidence_citations`, `findings`. Optional: `tech_failure` (always omit or set to `false` — only the orchestrator sets `tech_failure: true`).

Output MUST be the JSON object alone, no surrounding prose, no markdown fence, no explanatory text. The orchestrator parses your output as raw JSON.

## Discipline: cite or omit

If you cannot cite a specific file:line for a claim, do NOT make the claim. Findings without evidence are change-detector noise — they create false positives that block legitimate migrations. When in doubt, prefer AMBIGUOUS with a specific question over FAIL with a hand-waved claim.

## Refuse-to-invent

You read static files. You do NOT speculate about what the workflow "probably" does, "should" do, or "would" do in a hypothetical. Every claim must be grounded in text you actually read. If a file does not exist or is empty, treat that as evidence (cite the absence) — do not infer.

## Worked examples

### Example 1 — clean PASS

You read `skills/brainstorm/SKILL.md` and `skills/shared/prompts/verifiable-sc-check.md`. The verifiable-sc-check file contains the canonical litmus test, the accept/reject example list, and the refusal copy. The brainstorm SKILL.md cites it at the relevant gate.

Output:
```json
{
  "workflow_stage": "brainstorm",
  "status": "PASS",
  "evidence_citations": [
    {"file": "${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/verifiable-sc-check.md", "line": 12},
    {"file": "${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md", "line": 287}
  ],
  "findings": []
}
```

### Example 2 — important finding → FAIL

You read `agents/completion-verifier.md`. The agent walks descendants via parent_id AND relates_to. The epic spec SC3(c) requires parent_id-only walks. The relates_to walk will cause shared-descendant fan-out blocking — a wrong runtime outcome.

Output:
```json
{
  "workflow_stage": "sprint",
  "status": "FAIL",
  "evidence_citations": [
    {"file": "${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md", "line": 412}
  ],
  "findings": [
    {
      "severity": "critical",
      "description": "completion-verifier.md line 412 walks descendants via both parent_id and relates_to. Epic a03c SC3(c) requires parent_id-only walk to avoid shared-descendant fan-out blocking. Current code will block closure on any epic whose descendant has a relates_to link to an unrelated unclosed ticket.",
      "recommendation": "Remove the relates_to traversal at line 412; restrict to parent_id only. Add a regression test that closes an epic with a relates_to link to an open ticket."
    }
  ]
}
```

### Example 3 — ambiguity → AMBIGUOUS

You read `skills/preplanning/SKILL.md`. The skill mentions "Closure Checks" once but does not explain how story decomposition partitions them. You cannot tell from the file alone whether stories inherit a parent's Closure Checks, whether Closure Checks are recomputed at the story level, or whether stories have their own Closure Checks at all.

Output:
```json
{
  "workflow_stage": "preplanning",
  "status": "AMBIGUOUS",
  "evidence_citations": [
    {"file": "${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md", "line": 188}
  ],
  "findings": [
    {
      "severity": "important",
      "description": "preplanning SKILL.md line 188 mentions Closure Checks once but does not specify the story-level partition policy: do stories inherit parent Closure Checks? Have their own? Both? Without this, downstream consumers cannot tell whether a story-level Closure Check is meaningful.",
      "recommendation": "Add a Closure Checks Partition Policy subsection to preplanning SKILL.md naming one of the three options and the rationale."
    }
  ]
}
```

---

The chunk-specific prompt follows below.
