# ADR 0001: Outbound Jira Bridge Pattern

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-03-21

Technical Story: w21-vhms (ADR — outbound bridge architectural pattern)

## Context and Problem Statement

The Digital Service Orchestra ticket system (the tk/`ticket` CLI) stores tickets as event-sourced JSON files in a
`.tickets-tracker/` directory committed to a `tickets` git branch. When a developer creates or
updates a ticket locally, those changes must propagate to Jira so the two systems remain in sync.

Two constraints make a naive synchronous approach unworkable:

- **SC1 (push-trigger)**: Synchronization must fire automatically when ticket changes are pushed —
  the developer should not need to run a separate command.
- **SC9 (no local credentials)**: Jira API credentials must not be required on developer machines.
  Storing long-lived API tokens locally increases the blast radius of a compromised workstation.

`.claude/scripts/dso ticket sync` (the existing local synchronization command) runs the Atlassian CLI (ACLI) directly.
This requires local Jira credentials and runs synchronously in the developer's shell session.
It cannot satisfy SC1 (it is a pull, not a push trigger) or SC9 (credentials must be present
locally).

## Decision

Use a **GitHub Actions outbound bridge** composed of three parts:

1. **Workflow trigger** (`.github/workflows/outbound-bridge.yml`): Fires on every push to the
   `tickets` branch that touches `.tickets/**` files. The workflow runs in the GitHub Actions
   environment where Jira credentials are stored as repository secrets — never on developer
   machines.

2. **Bridge script** (`plugins/dso/scripts/bridge-outbound.py`): Parses `git diff HEAD~1 HEAD  # shim-exempt: ADR architecture reference
   --name-only` output to detect new ticket event files, filters out events that originated from
   the bridge itself (echo prevention via `env_id`), compiles the authoritative ticket state via
   `ticket-reducer.py` for STATUS events, and calls the ACLI integration layer for each change.
   Supported outbound event types: `CREATE`, `STATUS`, `COMMENT`, `LINK`, `UNLINK`, `REVERT`.

3. **ACLI integration layer** (`plugins/dso/scripts/acli-integration.py`): Wraps ACLI subprocess  # shim-exempt: ADR architecture reference
   calls (`createIssue`, `updateIssue`, `getIssue`) with retry logic and exponential backoff.
   Provides `create_issue`, `update_issue`, and `get_issue` as a clean interface callable from
   `bridge-outbound.py` via `importlib`.

After each successful Jira operation, the bridge writes a SYNC event file back to the ticket
directory. The SYNC event records the Jira key, local ticket ID, `env_id`, and GHA `run_id`.
These SYNC events serve two purposes: (a) they allow the inbound bridge to correlate local tickets
with Jira issues, and (b) they act as idempotency guards — if a SYNC event already exists for a
ticket, subsequent CREATE events are skipped.

### Echo prevention

The workflow-level `if` guard (`github.actor != BRIDGE_BOT_LOGIN`) prevents the bridge from
re-triggering when it commits SYNC events back to the `tickets` branch. The bridge also uses a
per-event `env_id` field (a UUID stored in `.tickets-tracker/.env-id`) to filter out events it
emitted in previous runs, preventing an infinite sync loop if the bot identity guard ever fails.

### SYNC event format

The bridge communicates with the inbound bridge via the SYNC event format defined in
`plugins/dso/docs/contracts/sync-event-format.md`. The outbound bridge is the **emitter** of this
format; the inbound bridge (story w21-gykt) is the **parser**. Both sides must treat all six
fields (`event_type`, `jira_key`, `local_id`, `env_id`, `timestamp`, `run_id`) as required.

## Consequences

### Positive

- **No local credentials required (SC9 satisfied)**: Jira API tokens live in GitHub Actions
  repository secrets. Developer machines never touch them.
- **Automatic push-trigger (SC1 satisfied)**: The workflow fires on every push to `tickets`
  without any manual developer action.
- **Audit trail**: SYNC event files committed to the `tickets` branch provide a durable,
  version-controlled record of every bridge operation, including the GHA `run_id` for traceability.
- **Idempotent operations**: Echo prevention (bot identity guard + `env_id` filtering) and
  idempotency guards (SYNC existence check, per-run `_status_updated` set) make the bridge safe
  to re-run on the same commit.
- **No new runtime dependencies**: `bridge-outbound.py` and `acli-integration.py` use stdlib only
  (`importlib`, `json`, `os`, `pathlib`, `subprocess`, `time`, `uuid`).

### Negative

- **~5-minute latency window**: GitHub Actions queuing introduces latency between a local `git push`
  and the corresponding Jira update. This is acceptable for an async workflow where developers do
  not need real-time Jira confirmation.
- **SYNC event format coupling**: The outbound bridge is tightly coupled to the SYNC event format
  contract. Any schema change (see `plugins/dso/docs/contracts/sync-event-format.md`) requires
  coordinated updates to both the outbound bridge (emitter) and the inbound bridge (parser).
- **ACLI dependency**: The bridge requires the Atlassian CLI to be downloaded and configured in
  the GHA runner environment. Version pinning (`ACLI_VERSION`) and SHA256 checksum verification
  (`ACLI_SHA256`) are enforced to mitigate supply-chain risk, but ACLI itself is a third-party
  binary not controlled by this project.
- **Bot identity required for echo prevention**: The workflow-level echo guard depends on
  `BRIDGE_BOT_LOGIN` being set as a repository variable. If unset, the workflow falls back to
  `dso-bridge[bot]` as a safe default (rather than silently bypassing the guard), but operators
  must configure this variable for production use.

## Alternatives Considered

### Alternative: Extend `.claude/scripts/dso ticket sync` to run in CI

Run the existing `.claude/scripts/dso ticket sync` command in a CI step instead of a dedicated bridge script.

**Rejected** because:
- `.claude/scripts/dso ticket sync` requires local ACLI credentials to be present on the runner or passed as environment
  variables. While CI can supply secrets, this approach re-introduces credential management
  complexity that the bridge pattern avoids.
- `.claude/scripts/dso ticket sync` runs synchronously and performs a full incremental scan of the ticket store. The
  outbound bridge uses `git diff` to process only the events introduced by the triggering commit,
  which is significantly more efficient for large ticket stores.
- `.claude/scripts/dso ticket sync` does not emit SYNC events — it cannot serve as the emitter side of the
  outbound/inbound bridge contract.
- Cannot satisfy SC1 (push-trigger) without additional wrapper logic equivalent to what the
  outbound bridge already provides.

## Links

- SYNC event format contract: `plugins/dso/docs/contracts/sync-event-format.md`
- Outbound bridge script: `plugins/dso/scripts/bridge-outbound.py`  # shim-exempt: ADR reference
- ACLI integration layer: `plugins/dso/scripts/acli-integration.py`  # shim-exempt: ADR reference
- GitHub Actions workflow: `.github/workflows/outbound-bridge.yml`
- Inbound bridge story: w21-gykt
- Parent epic: w21-8cw2
