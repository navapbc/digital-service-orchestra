# Drift Injection Test Harness

End-to-end validation that the dso-reconciler self-heals injected anomalies
against a real Jira sandbox environment.

## Sandbox Prerequisites

A dedicated Jira project keyed by `DRIFT_TEST_PROJECT_KEY` is required.
This project should be:
- Isolated from production data (sandbox only)
- Accessible to the API token used by the harness
- Configured to allow issue creation, label edits, and property writes

## Required Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `JIRA_API_TOKEN` | Yes | Atlassian API token with project read/write access |
| `JIRA_USER` | Yes | Atlassian account email used for Basic auth |
| `JIRA_BASE_URL` | Yes | Base URL (e.g., `https://your-org.atlassian.net`) |
| `DRIFT_TEST_PROJECT_KEY` | Yes | Jira project key (e.g., `DSOTEST`) |

## Per-Mode Invocation

```bash
# Orphan injection: Jira issue with no local ticket
./inject-and-heal.sh orphan

# Mislabel injection: Jira label does not match dso-id:<uuid>
./inject-and-heal.sh mislabel

# Missing-prop injection: dso_local_id entity property stripped
./inject-and-heal.sh missing-prop
```

## CI Behavior

- **Credentials absent**: harness exits 0 with `SKIP:` prefix on stderr.
  Tests are never hard-failed due to missing credentials in CI.
- **Reconcile fails to heal**: bridge-fsck exits non-zero after the
  reconciler pass → harness exits 1 (hard failure).

## Cleanup

All Jira issues created during injection are registered in a `CLEANUP_KEYS`
array and deleted via EXIT trap, regardless of test outcome.
