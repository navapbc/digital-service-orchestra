# Local Validation Sub-Agent Prompt

Run the project validation script and report results.
Do NOT fix any issues — only report pass/fail for each check.

## Config Keys Used

The orchestrator injects a `### Config Values` block before dispatching this prompt.
Expected keys (all optional — absent keys cause the section to be SKIPPED):

| Config Key           | Purpose                                           |
|----------------------|---------------------------------------------------|
| `commands.validate`  | Full validation gate command (lint + tests)       |
| `commands.test_e2e`  | End-to-end test command                           |
| `commands.test_visual` | Visual regression test command                  |
| `database.status_cmd` | Command to check if the database is running      |

The orchestrator provides these as a block like:
```
### Config Values
VALIDATE_CMD=<value or ABSENT>
TEST_E2E_CMD=<value or ABSENT>
TEST_VISUAL_CMD=<value or ABSENT>
DB_STATUS_CMD=<value or ABSENT>
```

## Commands to Run

1. `pwd`
2. If `DB_STATUS_CMD` is present and not `ABSENT`: run it and report whether the database container is running.
   If `DB_STATUS_CMD` is `ABSENT`: report Database: UNKNOWN (no status_cmd configured).

3. If `VALIDATE_CMD` is present and not `ABSENT`:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   <VALIDATE_CMD>
   ```
   **Bash timeout**: Use `timeout: 960000` (16 minutes). The smart CI wait can poll for up to 15 minutes.

   If `VALIDATE_CMD` is `ABSENT`: report Validation: SKIPPED (no validate command configured).

Parse the validation output and report:
- Format check: PASS/FAIL
- Lint: PASS/FAIL
- Type check: PASS/FAIL
- Unit tests: PASS/FAIL (include count: X passed, Y failed, if available)
- Lock file sync: PASS/FAIL (if applicable)
- Database: RUNNING/STOPPED/UNKNOWN

## E2E Test Gate (IMPORTANT)

After the validation command completes, inspect the e2e line in its output.
Apply this gate logic:

- `e2e: PASS` → report E2E: PASS (no action needed)
- `e2e: FAIL` or `e2e: TIMEOUT` → report E2E: FAIL and set local validation status to FAIL
- `e2e: SKIP (CI passing for main)` → this is the silent-skip path. Before accepting this as
  acceptable, run the port conflict pre-check below to determine whether E2E *could* have run.
  Then report E2E: WARN with a prominent warning in the summary (see below).
- E2E line absent from validation output → report E2E: WARN with explanation.
- `TEST_E2E_CMD` is `ABSENT` → report E2E: SKIPPED (no test_e2e command configured in config).
  Do NOT treat this as a WARN — it is a valid configuration choice.

## Port Conflict Pre-Check

Run this whenever e2e is SKIP or absent (but not when TEST_E2E_CMD is ABSENT):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Try to detect the app port from the project; fall back to 5001
APP_PORT=$(command -v make >/dev/null 2>&1 && make -C "$REPO_ROOT" --quiet --no-print-directory print-app-port 2>/dev/null || echo "5001")
OCCUPIED_BY=$(lsof -ti :"${APP_PORT}" 2>/dev/null || true)
if [ -n "$OCCUPIED_BY" ]; then
  PROC_NAME=$(ps -p "$OCCUPIED_BY" -o comm= 2>/dev/null || echo "unknown")
  echo "PORT_CONFLICT: Port ${APP_PORT} is occupied by PID ${OCCUPIED_BY} (${PROC_NAME})"
else
  echo "PORT_FREE: Port ${APP_PORT} is available"
fi
```

If `PORT_CONFLICT` is reported for a process NOT matching this project (e.g., not `python`, `flask`,
or `gunicorn`), include in the warning: "Port ${APP_PORT} occupied by ${PROC_NAME} — E2E may fail
due to port conflict even if re-run manually."

## E2E WARN Format

Use this format when e2e is SKIP or absent (and TEST_E2E_CMD is not ABSENT):

```
WARNING: E2E tests were SKIPPED — local regressions may escape to CI.
  Reason: CI passing for main (validation skipped E2E to save time)
  Port status: PORT_FREE / PORT_CONFLICT (include pre-check result)
  Impact: E2E tests are the primary gate for end-to-end regressions.
          A skip here means only CI will catch them, adding ~15-30 min
          latency to regression discovery.
  Action: Run '<TEST_E2E_CMD>' manually to verify, or push
          and wait for CI to run the full E2E suite.
```

Set local validation to **WARN** (not PASS and not FAIL) when E2E is skipped. WARN means:
"local static checks pass, but E2E coverage gap exists."

## Git State

Also check git state:
- `git status --short` (report any uncommitted changes)
- `git log --oneline -1` (report current HEAD commit)
- `git log HEAD..origin/$(git branch --show-current) --oneline 2>/dev/null` (report unpushed commits)

## Local Validation Status Rules

- **PASS**: all configured checks pass AND e2e is PASS (or e2e ran and passed)
- **WARN**: all static checks pass BUT e2e was SKIP or absent (include the WARNING block above)
- **FAIL**: any static check fails OR e2e is FAIL/TIMEOUT

Return a structured summary. Do NOT attempt fixes.
