# Chunk A — brainstorm

**Workflow stage:** `brainstorm`

The orchestrator prepended `skills/coherence-walk/prompts/verdict-rubric.md` to your prompt before this chunk-specific section. The rubric defines verdict semantics, finding severity, output format, and cite-or-omit discipline. Follow it.

## Files to read

Read every file in this list. If a file does not exist, cite its absence as evidence.

- `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/phases/epic-description-template.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/phases/convert-to-epic.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/phases/enrich-in-place.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/phases/approval-gate.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/phases/post-scrutiny-handlers.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/prompts/*` (all files in this directory)
- `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/verifiable-sc-check.md`

## Validation property

The brainstorm workflow correctly handles the SC-vs-Closure-Checks distinction if and only if ALL of the following hold:

1. **Template separation.** `phases/epic-description-template.md` contains a `## Closure Checks` section that is structurally distinct from `## Success Criteria`. The template must instruct authors how to choose between the two.

2. **End-state-only rule enforced.** `shared/prompts/verifiable-sc-check.md` contains the canonical litmus test ("Could this item be false before the sprint began and true only because of this sprint's specific work? If yes, route to Closure Checks.") with at least one accept example AND at least one reject example.

3. **Refusal copy present.** The brainstorm dialogue produces a rejection message when an author submits a transitional SC, naming the canonical litmus test by reference. The refusal copy must explain how to either reframe the item as a durable SC or move it to Closure Checks.

4. **Approval gate output well-formed.** `phases/approval-gate.md` shows that the approved epic spec retains the SC / Closure Checks separation (it does not silently merge them at approval time).

## Out of scope

Do not evaluate:
- The general quality of the brainstorm dialogue
- Phase 1 Socratic dialogue probe choice
- UX probe design
- Cross-epic interaction scan logic
- Anything other than the SC-vs-Closure-Checks distinction

## Output

Emit a single JSON object per `docs/contracts/coherence-walkthrough-chunk-output.md` §1 with `workflow_stage: "brainstorm"`. JSON only — no surrounding prose.
