# CI Failure Validation State File

Write this file before dispatching the `error-debugging:error-detective` sub-agent on CI failure so it can skip redundant diagnostics for categories that already passed locally.

## File Path

`/tmp/sprint-validation-<epic-id>.json`

## Schema

```json
{
  "version": 1,
  "epicId": "<epic-id>",
  "generatedAt": "<ISO-8601 timestamp>",
  "generatedBy": "sprint",
  "localCheckResults": {
    "format": "pass|fail",
    "lint_ruff": "pass|fail",
    "lint_mypy": "pass|fail",
    "test_unit": "pass|fail"
  },
  "ciFailure": {
    "url": "<CI run URL>",
    "failedJobs": ["<job names if available>"]
  },
  "epicInfo": {
    "epicId": "<epic-id>",
    "changedFiles": ["<files from git diff main...HEAD>"]
  }
}
```

Populate `localCheckResults` from the post-batch validation output across all batches. Categories that passed locally are unlikely to be the CI failure cause. Write using Bash (inline JSON). Overwritten if Phase 6 is re-entered.
