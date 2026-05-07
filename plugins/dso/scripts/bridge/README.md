# DSO <-> Jira Bridge

The bridge is a bidirectional synchroniser between the project's
event-sourced `.tickets-tracker/` orphan branch and a Jira Cloud project.
**Outbound** pushes local ticket events (CREATE / STATUS / EDIT /
COMMENT / LINK / FILE_IMPACT) to Jira; **inbound** polls Jira for issues
that have changed since the last run and writes corresponding event
files back into the tracker.  Both directions are designed to be
idempotent and to fail loudly via `BRIDGE_ALERT` event files rather than
silently dropping data.

## Key components

| File | Role |
|------|------|
| `../bridge-outbound.py` | Outbound entry point (`process_events` + CLI) |
| `../bridge-inbound.py` | Inbound entry point (Jira -> event files) |
| `../acli-integration.py` | `AcliClient` wrapping the `acli` binary + direct REST helpers |
| `_outbound_cursor.py` | SHA-checkpoint cursor (replaces fragile HEAD~1..HEAD diff) |
| `_outbound_api.py` | Parsing, env-id filtering, SYNC helpers |
| `_outbound_handlers.py` | One handler per event type + `BRIDGE_USER_MAP` resolution |
| `_inbound_api.py` | Jira fetch + `write_create_events` / `write_edit_event` / `write_status_event` |
| `_inbound_utils.py` | `_adf_to_text` (Jira ADF -> plain text), Jira timestamp parsing |
| `_sync_io.py` | Shared SYNC.json read/write |
| `_atomic.py` | Atomic JSON file writes |
| `_flap.py` | STATUS-flap detector (debounce noisy reducer output) |
| `_handle_*.py` | Inbound field handlers (status / type / edit / links / destructive guard) |
| `_comments_inbound.py` | Inbound comment importer |

## How the cursor works

The outbound bridge tracks its progress through the tickets branch via a
SHA checkpoint file at `.tickets-tracker/.outbound-checkpoint.json`
(`{"last_processed_sha": "...", "last_run_id": "..."}`).

* **Steady state.**  `fetch_events_since_cursor(tracker, cursor_sha)` runs
  `git log <cursor>..HEAD --diff-filter=A --name-only --format=%H` and
  returns one event dict per added event file across **every** commit in
  that range.  This replaces the chronic
  `git diff HEAD~1..HEAD` window which silently dropped every commit
  older than HEAD-1 (the **HEAD~1 blindness** bug — fix `5d93-8b62`).
* **Cold start.**  Missing or empty checkpoint -> `_seed_at_head`
  writes a checkpoint at `HEAD`, emits a `BRIDGE_ALERT` under the
  `__bridge__/` pseudo-ticket dir, and returns `[]` so the very first
  run does not replay all of history.
* **Recovery.**  If the stored SHA is unreachable (shallow clone,
  history rewrite, force-push), the bridge attempts
  `git fetch --deepen=50`, then `--unshallow`, then falls back to
  `_seed_at_head` with an alert.
* **Cap protection.**  More than `cap=500` distinct commits behind ->
  alert + reset to HEAD (operator must catch up manually).

After every successful pass, `process_events` advances the checkpoint
to the current `HEAD` SHA.  If processing was incomplete (a handler
raised), the checkpoint is left untouched so the next run retries the
same range.

## Environment variables

| Var | Required | Purpose |
|-----|----------|---------|
| `BRIDGE_ENV_ID` | yes (production) | Non-empty UUID identifying this bridge instance.  Outbound stamps every emitted event with it; inbound uses it for echo prevention.  Empty value = back-compat mode (no echo filtering). |
| `BRIDGE_USER_MAP` | optional | JSON dict mapping local display name / email -> Jira `accountId`.  Used by `handle_create_event` to resolve assignees.  No-match -> the issue is created with no assignee and a `BRIDGE_ALERT` is written.  Malformed JSON is treated as empty (fail-open). |
| `BRIDGE_BOT_LOGIN` | optional | GitHub login of the bridge bot (used by the workflow `if:` guard to suppress echo loops).  Defaults to `dso-bridge[bot]`. |
| `BRIDGE_BOT_NAME` / `BRIDGE_BOT_EMAIL` | optional | Identity used when committing SYNC events back to the tickets branch. |
| `JIRA_URL` / `JIRA_USER` / `JIRA_API_TOKEN` / `JIRA_PROJECT` | yes (production) | Jira Cloud credentials and project key passed to `AcliClient`. |
| `GH_RUN_ID` | optional | Stamped into SYNC events for traceability back to the GitHub Actions run. |

## Running the failure-injection tests

The round-trip and failure-injection matrix lives at
`tests/scripts/test_bridge_round_trip.py`.  All Jira interactions are
mocked — the suite never hits the network.

```bash
# Run every round-trip / failure-injection test
python3 -m pytest tests/scripts/test_bridge_round_trip.py -v

# Filter to a single bug class
python3 -m pytest tests/scripts/test_bridge_round_trip.py \
  -k "cursor_revert or env_id_revert or adf_isinstance or null_assignee" -v
```

The four failure-injection tests are intentionally separate functions
(not parametrised) so a CI failure names exactly which silent-drop bug
class regressed:

* `test_cursor_revert_drops_old_commits` — S1 cursor (`6b6e`)
* `test_env_id_revert_drops_all_events` — S2 filter back-compat (`3580`)
* `test_adf_isinstance_revert_drops_description` — S3 ADF (`5f23`)
* `test_null_assignee_revert_silently_fails` — S4 BRIDGE_USER_MAP (`7759`)

Adjacent unit suites worth knowing about:

* `tests/scripts/test_bridge_outbound_cursor.py` — cursor unit tests
* `tests/scripts/test_bridge_outbound.py` — handler unit tests
* `tests/scripts/test_bridge_inbound.py` — inbound unit tests

## Troubleshooting

`BRIDGE_ALERT` event files are the bridge's only out-of-band signal.
Search for them with:

```bash
git -C .tickets-tracker log --diff-filter=A --name-only --format= \
  | grep BRIDGE_ALERT.json | sort -u
```

Common reasons and remediations:

| Reason text contains | Cause | Fix |
|-----------------------|-------|-----|
| `cold-start` / `outbound-checkpoint reset` | First run, or cursor SHA unreachable -> seeded at HEAD | Expected on first run; investigate if recurring (history rewrite?) |
| `<n>-commit cap exceeded` | More than 500 commits since last run | Investigate why the bridge stopped; manually catch up if necessary |
| `BRIDGE_USER_MAP` | Local assignee not in `BRIDGE_USER_MAP` | Add the mapping (`{"<display name or email>": "<jira accountId>"}`) and re-run |
| `pre_migration_events_not_replayed` | One-shot alert when `BRIDGE_ENV_ID` transitions from unset to set | Informational only; pre-migration events are intentionally not replayed |
| `STATUS flap detected` | Reducer output oscillated past the threshold within the window | Inspect the ticket's STATUS event history; debounce upstream |
| `STATUS event dropped: no SYNC.json marker` | Local STATUS for a ticket never linked to Jira | The bridge attempts a retroactive CREATE; if that fails, repair manually |
| `403 delete denied` / `delete failed` | Jira refused issue deletion | Check service-account permissions or close instead of delete |
| `LINK event` | LINK target ticket is not yet synced to Jira | The next outbound run will retry once the target has a SYNC marker |

`BRIDGE_ALERT` events under `.tickets-tracker/__bridge__/` are
cursor-level alerts (no specific ticket); per-ticket alerts live under
the ticket's own directory.
