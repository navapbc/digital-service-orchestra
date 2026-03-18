# CI Status Sub-Agent Prompt

Check GitHub Actions CI workflow status for the current branch.
Do NOT fix any issues — only report status.

IMPORTANT: Do NOT use --wait flag (it blocks indefinitely). Use single-check mode.

## Config Keys Used

The orchestrator injects a `### Config Values` block before dispatching this prompt.
Expected keys:

| Config Key                    | Purpose                                              | Required? |
|-------------------------------|------------------------------------------------------|-----------|
| `ci.integration_workflow`     | GitHub Actions workflow name for integration tests   | Optional  |

The orchestrator provides these as a block like:
```
### Config Values
PLUGIN_SCRIPTS_DIR=<absolute path to plugin scripts directory>
INTEGRATION_WORKFLOW=<value or ABSENT>
```

When `INTEGRATION_WORKFLOW` is `ABSENT`, the integration workflow check is **skipped without error**.
This is expected behavior for projects that do not have a separate integration workflow.

## Commands to Run

1. `pwd`
2. `REPO_ROOT=$(git rev-parse --show-toplevel)`
3. Run the plugin's `ci-status.sh` script using the injected `PLUGIN_SCRIPTS_DIR`:
   ```bash
   "$PLUGIN_SCRIPTS_DIR/ci-status.sh"
   ```
   Exit code: 0 = success, 1 = failure, 2 = still running/queued

4. **Integration workflow check** (OPTIONAL — run only when `INTEGRATION_WORKFLOW` is not `ABSENT`):
   ```bash
   gh run list --workflow="<INTEGRATION_WORKFLOW>" --limit 1 --json status,conclusion,createdAt,url --jq '.[0]'
   ```
   If `INTEGRATION_WORKFLOW` is `ABSENT`: skip this step entirely. Report Integration tests: SKIPPED (not configured).
   This is not an error — it means the project has no separate integration workflow.

## Return

- CI workflow status: success/failure/pending/not_found
- If pending: report current state (queued/in_progress)
- If failed: which job(s) failed
- Run URL (if available)
- Integration tests: success/failure/pending/not_found/SKIPPED (last run date if available)
  - Report SKIPPED when `INTEGRATION_WORKFLOW` is absent from config — this is normal, not a warning.

Do NOT attempt fixes.
