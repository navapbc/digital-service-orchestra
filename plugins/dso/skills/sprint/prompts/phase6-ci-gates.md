# Phase 6: Integration Test Gate, CI Verification, and E2E Tests

These steps execute after all tasks close, before the completion verifier (Step 0.75).

## Initialize Post-Loop Progress Checklist

Complete all remaining batch tasks, then create new tasks via `TaskCreate` for the post-epic validation steps:

```
[ ] Integration test gate
[ ] Wait for CI (SHA-based)
[ ] Run E2E tests locally
[ ] Full validation (/dso:validate-work + epic scoring)
[ ] Remediation (if score < 5 → returns to batch loop)
[ ] Close out (close epic + /dso:end-session)
```

Mark each item `in_progress` when starting and `completed` when done. If remediation triggers (score < 5), check off "Remediation" and return to Phase 3 (Batch Preparation).

## Step 0: Integration Test Gate (/dso:sprint)

Check if this epic modified integration-relevant code and verify the External API Integration Tests workflow:

1. Get changed files: `git diff --name-only main...HEAD`
2. Check for integration-relevant changes by scanning file paths for:
   - `models/`, `migrations/`, `schema` (DB changes)
   - `providers/`, `services/` with external API calls
   - `routes.py`, `endpoints` (API contract changes)
3. Check the last "External API Integration Tests" workflow run:
   ```bash
   gh run list --workflow="External API Integration Tests" --limit 1 --json status,conclusion,createdAt,url --jq '.[0]'
   ```
4. Decision:
   - If integration-relevant changes detected AND last run is >24h old OR last run failed:
     - Trigger a new run: `gh workflow run "External API Integration Tests"`
     - Log: "Triggered External API Integration Tests — changes affect integrations."
     - Poll status (max 15 min): `gh run list --workflow="External API Integration Tests" --limit 1 --json status,conclusion --jq '.[0]'`
   - If last run passed and is recent (<24h): Log "Integration tests: PASS (last run: {createdAt})"
   - If no integration-relevant changes: Log "No integration-relevant changes — skipping integration test gate"
5. If integration tests fail after trigger: create a P1 bug issue and include in the Phase 6 report. Continue with /dso:validate-work (non-blocking but flagged).

## Step 0.5: CI Verification + E2E Tests (/dso:sprint)

### Step 0.5a: Wait for CI Containing the Final Commit

**Docs-only detection (run first)**:

```bash
CODE_FILES=$(git diff --name-only main...HEAD | grep -vE '\.(md|txt|json)$|^\.tickets-tracker/|^\.claude/|^docs/' | head -1)
```

If `CODE_FILES` is empty: Log "Docs-only changes detected — skipping CI verification." Skip to Step 0.75.

If `CODE_FILES` is non-empty:

```bash
.claude/scripts/dso ci-status.sh --wait
```

| CI Result | Action |
|-----------|--------|
| `success` | Proceed to Step 0.5b |
| `failure` | Write the validation state file (see below), dispatch an `error-debugging:error-detective` sub-agent (model: `sonnet`) with the CI run URL and failed job names. Follow the test-failure-dispatch protocol (`prompts/test-failure-dispatch-protocol.md`). Commit+push, restart Step 0.5a. If still failing after one attempt → Phase 8 (Graceful Shutdown). |
| Not found after 30 min | Run `gh run list --workflow=CI --limit 10` to check if CI triggered. Report to user. |

### Validation State File (CI failure context for error-detective sub-agent)

Before dispatching the error-detective sub-agent on CI failure, write the validation state file per `prompts/ci-failure-validation-state.md`.

### Step 0.5b: Run E2E Tests

Run the full E2E suite locally.

```bash
cd $(git rev-parse --show-toplevel)/app && make test-e2e
```

**Interpret results:**
- **Pass** → proceed to Step 0.75
- **Fail** → do NOT proceed. Dispatch a debugging sub-agent FIRST before creating bug issues.

### E2E Test Failure Sub-Agent Delegation (Phase 6 Step 0.5b)

When E2E tests fail, follow `prompts/test-failure-dispatch-protocol.md` with these caller-specific fields:
- `test_command`: `cd $(git rev-parse --show-toplevel)/app && make test-e2e`
- `changed_files`: files changed across all batches (`git diff --name-only main...HEAD`)
- `task_id`: a tracking task ID for checkpoint notes
- `context`: `sprint-e2e`

On `FAIL` after attempt 2: create a P1 bug issue for each failing test, set as child of epic, return to Phase 3 (Batch Preparation).
