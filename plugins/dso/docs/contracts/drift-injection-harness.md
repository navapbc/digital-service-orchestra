# Contract: Drift Injection Harness

- Status: accepted
- Scope: dso-reconciler integration testing (inject-and-heal.sh + ticket-bridge-fsck.py)
- Date: 2026-05-22
- Version: 1.0

## Purpose

The drift injection harness (`tests/drift_injection/inject-and-heal.sh`) provides
end-to-end validation that the dso-reconciler's self-healing behavior works correctly
against a real Jira sandbox environment.

## Three Injection Modes

### orphan

Injects a Jira issue with no corresponding local ticket. Creates a mapping
anomaly where the Jira side exists but the local tracker has no record.
In bridge-fsck terms: produces an orphan mapping entry.

### mislabel

Creates a Jira issue + local ticket pair, then overwrites the Jira label
with a value that does not match the `dso-id:<uuid>` label. In bridge-fsck
terms: label mismatch produces a BRIDGE_ALERT.

### missing-prop

Creates a Jira issue + local ticket pair, then strips the `dso_local_id`
entity property from the Jira issue. In bridge-fsck terms: missing property
produces a BRIDGE_ALERT tagged `missing-dso-local-id`.

## Required Environment Variables

| Variable | Description |
|----------|-------------|
| `JIRA_API_TOKEN` | Atlassian API token with read/write access to the sandbox project |
| `DRIFT_TEST_PROJECT_KEY` | Jira project key for the sandbox (e.g., `DSOTEST`) |

CI skip-not-fail rule: when either variable is absent, the harness exits 0
with a `SKIP:` prefix on stderr. Tests are never hard-failed due to missing
credentials in CI.

## Subcommand Surface

```text
inject-and-heal.sh <subcommand>

Subcommands:
  orphan        Inject orphan anomaly and verify self-healing
  mislabel      Inject label mismatch and verify self-healing
  missing-prop  Inject missing dso_local_id property and verify self-healing
```

## Assertion Semantic

For each mode, the harness:
1. Asserts `ticket-bridge-fsck.py` exits non-zero **before** reconciliation (drift present)
2. Runs `python -m dso_reconciler`
3. Asserts `ticket-bridge-fsck.py` exits zero **after** reconciliation (drift healed)

A mode passes when step 3 exits 0. A mode fails when bridge-fsck remains
non-zero after the reconciler pass.

## Cleanup

All Jira issues created during injection are registered in a `CLEANUP_KEYS`
array and deleted via `EXIT` trap regardless of test outcome.
