# Chunk C — implementation-plan

**Workflow stage:** `implementation-plan`

The orchestrator prepended `skills/coherence-walk/prompts/verdict-rubric.md` to your prompt before this chunk-specific section. The rubric defines verdict semantics, finding severity, output format, and cite-or-omit discipline. Follow it.

## Files to read

Read every file in this list. If a file does not exist, cite its absence as evidence.

- `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/prompts/*` (all files in this directory)
- `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/docs/reviewers/*` (if present)
- Any other file under `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/` referenced from SKILL.md

## Validation property

The implementation-plan workflow correctly handles the SC-vs-Closure-Checks distinction if and only if ALL of the following hold:

1. **Task AC partitioning excludes Closure Checks.** When implementation-plan partitions story Done Definitions across tasks (each DD owned by exactly one task), Closure Check items from the parent epic MUST NOT be assigned to tasks as task-level Acceptance Criteria. Closure Checks are validated once at epic closure by the completion-verifier, not per-task.

2. **AC text does not conflate.** Task Acceptance Criteria templates and the AC library do not mix end-state and transitional phrasing. Tasks may produce one-time outcomes (their work is by definition transitional), but the AC text must not claim to verify a Closure Check.

3. **No reverse propagation.** The implementation-plan workflow does not write Closure Check items back into the epic or into story DDs as a side-effect of task decomposition. Closure Checks are a property of the epic; tasks do not author them.

4. **AC library distinguishes if it references Closure Checks at all.** If `docs/ACCEPTANCE-CRITERIA-LIBRARY.md` (or its equivalent) mentions Closure Checks, the mention must distinguish AC verification from Closure Check verification.

## Out of scope

Do not evaluate:
- The general quality of task decomposition
- Approach proposal generation
- File-impact enrichment
- Retry budget design
- Anything other than the SC-vs-Closure-Checks distinction

## Output

Emit a single JSON object per `docs/contracts/coherence-walkthrough-chunk-output.md` §1 with `workflow_stage: "implementation-plan"`. JSON only — no surrounding prose.
