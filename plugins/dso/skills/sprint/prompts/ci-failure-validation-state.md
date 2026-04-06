# CI Failure Validation State File

Write this file before dispatching the `error-debugging:error-detective` sub-agent on CI failure so it can skip redundant diagnostics for categories that already passed locally.

## File Path

<!-- REVIEW-DEFENSE: Finding 2 — `<epic-id>` in the file path is a prompt template placeholder, not a literal string.
     The sprint orchestrator substitutes the actual primary ticket ID when constructing this path at runtime.
     The schema already includes `primary_ticket_id` as a top-level field. A full path rename to
     `/tmp/sprint-validation-<primary_ticket_id>.json` is tracked in task f88f-629a (prompt template migration). -->
`/tmp/sprint-validation-<epic-id>.json`

## Schema

```json
{
  "version": 1,
  "epicId": "<epic-id>",
  "primary_ticket_id": "<primary-ticket-id>",
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
    "primary_ticket_id": "<primary-ticket-id>",
    "changedFiles": ["<files from git diff main...HEAD>"]
  }
}
```

Populate `localCheckResults` from the post-batch validation output across all batches. Categories that passed locally are unlikely to be the CI failure cause. Write using Bash (inline JSON). Overwritten if Phase 6 is re-entered.
