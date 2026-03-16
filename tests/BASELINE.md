# Plugin Test Suite — Green Baseline

## Baseline Run

| Field | Value |
|-------|-------|
| Timestamp | 2026-02-28T14:30:00Z |
| git SHA | 8027d415fc39d2535fb96e824e1fe2062424bc35 |
| Runner | `${CLAUDE_PLUGIN_ROOT}/tests/run-all.sh` |
| Overall Result | PASS |

## Suite Results

| Suite | PASSED | FAILED | Notes |
|-------|--------|--------|-------|
| Evals (`${CLAUDE_PLUGIN_ROOT}/tests/evals/run-evals.sh`) | 24 | 0 | 24 skill-activation file_exists checks |
| Hook Tests (`${CLAUDE_PLUGIN_ROOT}/tests/hooks/run-hook-tests.sh`) | 218 | 0 | All hook test files |
| Script Tests (`${CLAUDE_PLUGIN_ROOT}/tests/scripts/run-script-tests.sh`) | 76 | 0 | All script test files. Phase 5: +5 cross-stack integration test files (test-cross-stack-go.sh, test-cross-stack-lockpick-snapshot.sh, test-cross-stack-makefile.sh, test-cross-stack-node.sh, test-cross-stack-regression.sh) pass and exit 0; 26 additional tests counted separately (PASSED: N format, not yet aggregated by run-script-tests.sh). |

## Old Script Path Callers

Checked for callers pointing to `scripts/test-validation-gate`, `scripts/test-post-tool-use`,
`scripts/test-record-review` in `.github/`, `Makefile`, and `scripts/`:

**No callers found.** If shims exist at old paths, shim cleanup is ready to proceed as a
separate task (do NOT remove shims here).

## Reproduction

Run the full suite from the repository root:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/tests/run-all.sh
```

Expected exit code: `0`
