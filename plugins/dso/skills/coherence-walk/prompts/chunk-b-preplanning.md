# Chunk B — preplanning

**Workflow stage:** `preplanning`

The orchestrator prepended `skills/coherence-walk/prompts/verdict-rubric.md` to your prompt before this chunk-specific section. The rubric defines verdict semantics, finding severity, output format, and cite-or-omit discipline. Follow it.

## Files to read

Read every file in this list. If a file does not exist, cite its absence as evidence.

- `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/prompts/*` (all files in this directory)
- `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/docs/reviewers/*` (if present)
- Any other file under `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/` referenced from SKILL.md

## Validation property

The preplanning workflow correctly handles the SC-vs-Closure-Checks distinction if and only if ALL of the following hold:

1. **SC inheritance is partitioned.** When the story-decomposer drafts story Done Definitions tied to epic Success Criteria, the decomposition does not silently fold Closure Check items into story DDs. Either: (a) Closure Checks remain on the epic and stories carry only end-state DDs, OR (b) the SKILL.md explicitly names a story-level Closure Checks partition policy.

2. **End-state-only DD semantics.** Story Done Definitions inherit the end-state-only character of their parent Success Criteria. The preplanning prompts must not generate transitional DDs (e.g., "OAuth migration is complete") for stories whose parent SC is end-state ("the system supports OAuth").

3. **Distinction preserved through decomposition.** When the story-decomposer agent runs, the prompt files it loads (via SKILL.md references) must not collapse the SC / Closure Checks distinction. The Closure Checks remain visible to downstream consumers (implementation-plan, completion-verifier) after preplanning completes.

4. **Annotation discipline.** If preplanning emits "Satisfies <SC-id>" or similar annotations on draft stories, those annotations must distinguish SC-satisfaction from Closure-Check-satisfaction.

## Out of scope

Do not evaluate:
- The general quality of story decomposition
- Adversarial review machinery (red/blue team)
- UI designer dispatch logic
- Scrutiny pipeline reuse from brainstorm
- Anything other than the SC-vs-Closure-Checks distinction

## Output

Emit a single JSON object per `docs/contracts/coherence-walkthrough-chunk-output.md` §1 with `workflow_stage: "preplanning"`. JSON only — no surrounding prose.
