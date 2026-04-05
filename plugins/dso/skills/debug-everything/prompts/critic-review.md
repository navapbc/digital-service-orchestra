## Code Review: Post-Fix Validation

Review the following diff for quality and correctness concerns.

**Note to orchestrator**: Before launching this sub-agent, capture the diff in the
orchestrator and replace the placeholder below. Sub-agents receive a stale git status
snapshot and may not see current uncommitted changes reliably.

## Diff
```diff
{full_diff captured by orchestrator via `git diff`}
```

Evaluate ONLY these criteria (skip if not applicable):
1. **Root cause vs symptom**: Does the fix address the actual root cause, or just suppress the error?
2. **Regression risk**: Could this change break something tests don't cover?
3. **Convention violations**: Does the fix follow existing patterns in the codebase?
4. **Scope creep**: Does the diff include changes unrelated to the fix?

Report ONLY high-confidence concerns (>80% sure it's a real issue).
Format: `PASS` or `CONCERN: <1-sentence description>`.

**READ-ONLY ENFORCEMENT**: Read and follow `prompts/shared/read-only-enforcement.md`.
