# Chunk E — commit-and-review

**Workflow stage:** `commit-and-review`

The orchestrator prepended `skills/coherence-walk/prompts/verdict-rubric.md` to your prompt before this chunk-specific section. The rubric defines verdict semantics, finding severity, output format, and cite-or-omit discipline. Follow it.

## Files to read

Read every file in this list. If a file does not exist, cite its absence as evidence.

- `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md`
- `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-WORKFLOW.md`
- `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-light.md`
- `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-standard.md`
- `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-arch.md`
- `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-correctness.md`
- `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-hygiene.md`
- `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-verification.md`
- `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-arbiter.md`
- Any other `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-*.md` file present in the repo

## Validation property

The commit-and-review workflow correctly handles the SC-vs-Closure-Checks distinction if and only if ALL of the following hold:

1. **Reviewers do not author Closure Checks.** Code review findings are limited to code (diff, files modified, tests, lint, security). Reviewers do not add or remove Closure Check items on tickets. The review-workflow prompts must not direct reviewers to evaluate Closure Checks.

2. **Review verdict does not block Closure Check verification.** REVIEW-WORKFLOW.md and the code-reviewer agents emit findings on code, not on planning artifacts. A review PASS does not imply Closure Checks pass; the completion-verifier is the separate authority for that. If review and verifier are conflated in any file, that is a finding.

3. **Failure surfaces remain distinct.** A code review FAIL and a Closure Check FAIL produce visibly different signals in the workflow (different artifacts, different blocking-gate identifiers, different remediation paths). Reviewers do not silently absorb Closure Check failures into their findings, and the completion-verifier does not silently absorb code findings.

4. **Commit workflow does not mutate Closure Checks.** COMMIT-WORKFLOW.md does not edit ticket descriptions, add Closure Check items, or transition Closure Check state. The commit phase records artifacts (test status, review status, reviewer findings hash) without touching planning intent.

## Out of scope

Do not evaluate:
- The general quality of code review tier classification
- Reviewer model selection (light / standard / deep)
- Autonomous resolution loop design
- False-positive escape valve (`/dso:fp-recovery`)
- Anything other than the SC-vs-Closure-Checks distinction

## Output

Emit a single JSON object per `docs/contracts/coherence-walkthrough-chunk-output.md` §1 with `workflow_stage: "commit-and-review"`. JSON only — no surrounding prose.
