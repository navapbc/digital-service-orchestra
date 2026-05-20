# Chunk D — sprint

**Workflow stage:** `sprint`

The orchestrator prepended `skills/coherence-walk/prompts/verdict-rubric.md` to your prompt before this chunk-specific section. The rubric defines verdict semantics, finding severity, output format, and cite-or-omit discipline. Follow it.

## Files to read

Read every file in this list. If a file does not exist, cite its absence as evidence.

- `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/sprint/prompts/*` (all files in this directory)
- `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md`
- Any other file referenced from sprint SKILL.md's Phase F Step 18 (story closure) or Phase G Step 2 (epic closure) verifier-dispatch path

## Validation property

The sprint workflow correctly handles the SC-vs-Closure-Checks distinction if and only if ALL of the following hold:

1. **Verifier reads Closure Checks separately.** `agents/completion-verifier.md` has code paths that read the `## Closure Checks` section distinctly from end-state items (Success Criteria for epics, Done Definitions for stories). The verifier validates each Closure Check one-shot at closure.

2. **Subtree walk via parent_id only.** The completion-verifier walks descendant tickets via `parent_id` only — NOT `relates_to` or `depends_on`. This avoids shared-descendant fan-out blocking. If the agent file walks via any other link type, that is a critical finding.

3. **Closed/deleted descendants skipped.** The verifier skips descendants in `closed` or `deleted` status during the subtree walk. Blocked status is treated as open unless all blockers are terminal.

4. **Legacy compatibility.** Tickets without a `## Closure Checks` section are treated as having zero Closure Checks (a pass), preserving legacy compatibility. Absence of the section is not a failure mode.

5. **Sprint orchestrator dispatches the verifier with the correct ticket scope.** Phase F Step 18 dispatches the verifier with a story ID; Phase G Step 2 dispatches with an epic ID. The dispatch shape (named subagent_type, fallback to general-purpose with verbatim agent file) is not inline-paraphrased.

6. **Verifier emits WARN, not BLOCK, on open descendants without Closure Checks.** The completion-verifier output format distinguishes "open descendant has unresolved Closure Check" (BLOCK) from "open descendant exists but has no Closure Checks at all" (WARN).

## Out of scope

Do not evaluate:
- The general sprint orchestration design
- Phase 1 heuristic coherence-walk.sh (it is Phase 1; you are Phase 2)
- Batch dispatch and worktree isolation
- Sub-agent boundary rules
- Anything other than the SC-vs-Closure-Checks distinction in sprint closure paths

## Output

Emit a single JSON object per `docs/contracts/coherence-walkthrough-chunk-output.md` §1 with `workflow_stage: "sprint"`. JSON only — no surrounding prose.
