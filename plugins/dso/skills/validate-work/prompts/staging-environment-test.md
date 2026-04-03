# Staging Environment Test

Validate the staging environment using a tiered approach that minimizes token usage.
Follow the `/dso:playwright-debug` 3-tier process: deterministic checks first,
targeted `@playwright/cli run-code` second, full CLI only as last resort.

Do NOT create bugs or fix issues — only report findings.

<!-- CONFIG BLOCK (injected by orchestrator at runtime) -->
<!-- staging.url: {STAGING_URL} -->
<!-- staging.test: {STAGING_TEST} -->
<!-- staging.routes: {STAGING_ROUTES} -->
<!-- staging.health_path: {STAGING_HEALTH_PATH} -->

---

## PRE-FLIGHT CHECK

Before running any browser-based checks, verify `@playwright/cli` is available:

```bash
# Pre-flight: confirm CLI is installed and accessible
if ! npx @playwright/cli --version 2>/dev/null; then
  echo "PRE-FLIGHT FAIL: @playwright/cli not found. Install with: npm install @playwright/cli"
  echo "Falling back to curl-only checks."
  PLAYWRIGHT_AVAILABLE=false
else
  echo "PRE-FLIGHT PASS: $(npx @playwright/cli --version)"
  PLAYWRIGHT_AVAILABLE=true
fi
```

If `PLAYWRIGHT_AVAILABLE=false`, skip all Tier 2 browser checks and report them as
`SKIPPED (cli-not-installed)`. Continue with Tier 0 and Tier 1 (curl-based) checks.

---

## DISPATCH (read this first)

The orchestrator injects `staging.test` from `workflow-config.yaml`. Determine the dispatch mode before proceeding:

### Mode A — Script dispatch (`staging.test` ends in `.sh`)

If the config value ends in `.sh`, execute it as a shell script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
TEST_SCRIPT="{STAGING_TEST}"   # injected by orchestrator
bash "$REPO_ROOT/$TEST_SCRIPT"
SCRIPT_EXIT=$?
```

**Exit code contract:**
- `0` = all tests passed (PASS)
- Non-zero = one or more tests failed (FAIL)
- Any unexpected exit code: report "Script returned exit code <N>." and mark FAIL.

Report the script output verbatim. Skip to the **Return** section.

---

### Mode B — Prompt dispatch (`staging.test` ends in `.md`)

If the config value ends in `.md`, read the file and use it as your primary test guidance:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
TEST_PROMPT="{STAGING_TEST}"   # injected by orchestrator
cat "$REPO_ROOT/$TEST_PROMPT"
```

Follow the instructions in that file as your primary guidance for this check.
Return results in the **Return** format at the bottom.

---

### Mode C — Unrecognized extension

If `staging.test` is set but has an extension other than `.sh` or `.md`, report:

```
ERROR: staging.test path '<path>' has unrecognized extension '<ext>'.
Expected .sh (executed as shell script) or .md (used as sub-agent prompt).
Custom test SKIPPED — falling back to generic tiered tests.
```

Then proceed with the generic tiered tests (Mode D) as a fallback.

---

### Mode D — Generic tiered validation (`staging.test` absent, or unrecognized extension fallback)

If no `staging.test` is configured, run the generic tiered validation below.

**Token budget target**: <=30k tokens for a full staging validation run.

---

## CHANGE SCOPE (read this first)

The caller may have appended a `### Change Scope` block below the prompt. Before running any checks, read it to determine what changed and apply tiered test selection.

### UI File Patterns

A change is considered **UI-affecting** if any file in `CHANGED_FILES` matches:

| Pattern | Reason |
|---------|--------|
| `*.html` (in templates/) | Template changes — direct UI output |
| `*.css` | Stylesheet changes affect rendered appearance |
| `*_routes.py` | Route handlers can change page structure/redirects |
| `*/blueprints/` | Blueprint modules contain routes and view logic |
| `*/static/js/` | Frontend JavaScript directly changes browser behavior |
| `*/static/css/` | CSS in static directory |

A change is **backend-only** if no files match any UI pattern.

### Tiered Test Selection

**Step 0 — Evaluate CHANGED_FILES**:

1. If no `### Change Scope` block was provided: default to FULL_BROWSER mode.
2. If `CHANGED_FILES` is empty or the block lists no files: default to FULL_BROWSER mode.
3. If files are listed, scan against the UI file patterns above:
   - At least one file matches a UI pattern → `TEST_MODE=FULL_BROWSER`
   - No files match → `TEST_MODE=API_ONLY`
   - `VISUAL_REGRESSION=fail` (from caller context) → override to `TEST_MODE=FULL_BROWSER`

Log your decision: `"Change scope evaluated: TEST_MODE={FULL_BROWSER|API_ONLY}. Matched UI files: [list] | No UI files matched."`

---

## TIER 0 — Deterministic Pre-Checks (no CLI needed)

Run local deterministic tests before any live environment interaction:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
STAGING_URL="{STAGING_URL}" HEALTH_PATH="{STAGING_HEALTH_PATH}" ROUTES="{STAGING_ROUTES}" bash ".claude/scripts/dso staging-smoke-test.sh"
```

**Interpret Tier 0 results:**
- Health endpoint `200` → PASS. Continue to Tier 1.
- Health endpoint `5xx` or `error` → FAIL. Report STAGING_UNREACHABLE and skip Tiers 1-2.
- Route scan: any `5xx` or `error` → note as WARN but continue.

---

## TIER 1 — API-Driven Checks (prefer over browser where possible)

In `API_ONLY` mode, run Tier 1 only (no Playwright). In `FULL_BROWSER` mode, run Tier 1 then Tier 2.

Perform HTTP-level API checks against the staging URL:

```bash
STAGING_URL="{STAGING_URL}"

# Route accessibility check (all configured routes)
IFS=',' read -ra ROUTE_LIST <<< "{STAGING_ROUTES}"
for route in "${ROUTE_LIST[@]}"; do
  route="$(echo "$route" | xargs)"
  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "$STAGING_URL$route" 2>/dev/null || echo "error")
  echo "Tier 1 route $route: $STATUS"
done
```

Report each route check as PASS (2xx or 3xx) or FAIL (5xx or curl error).

In `API_ONLY` mode, include in the summary:
`"TEST_MODE=API_ONLY: Browser checks skipped (no UI files in change scope). API route checks substituted."`

---

## TIER 2 — @playwright/cli Browser Checks (FULL_BROWSER mode only)

Only run Tier 2 when `TEST_MODE=FULL_BROWSER` and `PLAYWRIGHT_AVAILABLE=true` (pre-flight passed).

If `PLAYWRIGHT_AVAILABLE=false`, skip all Tier 2 phases and report them as `SKIPPED (cli-not-installed)`.

Use a named session scoped to the current worktree for isolation:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_ID=$(basename "$REPO_ROOT")
SESSION_NAME="staging-test-${WORKTREE_ID}"
```

**Phase 1 — Infrastructure Health** (prefer API-driven):
- Use curl: `curl -sf {STAGING_URL}{STAGING_HEALTH_PATH}` — if 200, PASS without CLI.
- Only open a browser session if curl is not reachable.

**Phase 2 — Browser Console Error Detection**:

Open a named session, navigate to staging, collect console messages, then close:

```bash
# Open session
npx @playwright/cli open -s="$SESSION_NAME"

# Navigate and collect console errors via run-code
npx @playwright/cli run-code -s="$SESSION_NAME" "
async (page) => {
  await page.goto('{STAGING_URL}');
  const errors = [];
  page.on('console', msg => {
    if (msg.type() === 'error') errors.push(msg.text());
  });
  await page.waitForLoadState('networkidle').catch(() => {});
  return {
    pageLoaded: true,
    consoleErrors: errors,
    hasConsoleErrors: errors.length > 0,
  };
}
"
```

**Output validation**: The `run-code` subcommand exits 0 on success, non-zero on error.
Parse the JSON return value from stdout. Report PASS if `hasConsoleErrors: false`, WARN if
`hasConsoleErrors: true` (list errors).

```bash
# Collect console output for parsing
npx @playwright/cli console -s="$SESSION_NAME"
```

**Phase 3 — Route Coverage** (spot-check configured routes via browser):

```bash
npx @playwright/cli run-code -s="$SESSION_NAME" "
async (page) => {
  const baseUrl = '{STAGING_URL}';
  const routes = '{STAGING_ROUTES}'.split(',').map(r => r.trim());
  const results = {};
  for (const route of routes) {
    const resp = await page.request.get(\`\${baseUrl}\${route}\`);
    results[route] = resp.status();
  }
  return results;
}
"
```

**Output validation**: Exit code 0 = success. Parse route status codes from JSON stdout.
Report each route PASS (2xx/3xx) or FAIL (5xx or error).

**Cleanup — close the session when done**:

```bash
npx @playwright/cli close -s="$SESSION_NAME"
```

---

## RESILIENCE

If `@playwright/cli` cannot reach staging (navigation timeout, connection refused):
- Report: STAGING_UNREACHABLE with the specific error.
- Include: "Staging site unreachable. Check environment health manually. Deployment may still be in progress."
- Close the session before exiting: `npx @playwright/cli close -s="$SESSION_NAME"`
- Do NOT retry navigation.

If a staging bug is observed (unexpected error, broken UI, wrong data):
- Take a screenshot for specific bug evidence:
  ```bash
  npx @playwright/cli screenshot -s="$SESSION_NAME" --filename=".claude/screenshots/<bug-name>.png"
  ```
- Include the screenshot filename in the report as evidence.
- Report the specific error pattern.

If test results are inconclusive (intermittent timeouts, partial page loads):
- Report as INCONCLUSIVE (not FAIL) with the `run-code` result as evidence.
- Do NOT take a screenshot.
- Include: "Results inconclusive — staging may still be deploying or under load. Wait 5 minutes and re-run, or investigate manually."

## FALLBACK (if @playwright/cli not available)

Use curl commands:
- `curl -sf {STAGING_URL}{STAGING_HEALTH_PATH}` — health check
- For each route in `staging.routes`: `curl -sf {STAGING_URL}<route>` — route check

Report what can be verified via API only; mark browser-only checks as `SKIPPED (cli-not-installed)`.

---

## Return

Return a structured summary:

```
- Test dispatch mode: Script / Prompt / Unrecognized extension fallback / Generic tiered
- Test mode: FULL_BROWSER / API_ONLY (with reason)
- Pre-flight: PASS / FAIL / SKIPPED
- Tier 0 (health + route scan): PASS/FAIL/WARN
- Tier 1 (API route checks): PASS/FAIL/SKIPPED
- Tier 2 Phase 1 (infrastructure health): PASS/FAIL/SKIPPED
- Tier 2 Phase 2 (console error detection): PASS/WARN/SKIPPED
- Tier 2 Phase 3 (route coverage): PASS/FAIL/SKIPPED
- Overall staging test: PASS/WARN/FAIL
  - WARN if TEST_MODE=API_ONLY (browser not tested)
  - WARN if console errors detected but no hard failures
  - FAIL if any Tier 0 health check failed or any Tier 2 phase FAIL
  - FAIL if @playwright/cli exit code non-zero in a required phase
```

Exit code interpretation:
- Exit 0 from `npx @playwright/cli run-code` = command executed successfully
- Non-zero exit = CLI error or browser automation failure (mark phase FAIL)

Do NOT create issues. Do NOT fix problems. Read-only verification only.

## READ-ONLY ENFORCEMENT

You are a read-only reporting agent. You MUST NOT modify any files or system state.

**STOP immediately** if you find yourself about to use any of these tools or commands:
- **Edit** — forbidden. Do not edit any file.
- **Write** — forbidden. Do not write any file.
- **Bash with modifying commands** — forbidden:
  - `git commit`, `git push`, `git add`, `git checkout`, `git reset`
  - `.claude/scripts/dso ticket transition`, `.claude/scripts/dso ticket create`
  - `make`, `pip install`, `npm install`, `poetry install`
  - Any command that changes system state

If you detect a problem, you must ONLY report it. You must not fix it.
Fixing is the orchestrator's job, not yours. TERMINATE your response with findings only.
