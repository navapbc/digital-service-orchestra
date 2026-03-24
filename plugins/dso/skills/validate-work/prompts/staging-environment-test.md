# Staging Environment Test

Validate the staging environment using a tiered approach that minimizes Playwright MCP
token usage. Follow the `/dso:playwright-debug` 3-tier process: deterministic checks first,
targeted `browser_run_code` second, full MCP only as last resort.

Do NOT create bugs or fix issues — only report findings.

<!-- CONFIG BLOCK (injected by orchestrator at runtime) -->
<!-- staging.url: {STAGING_URL} -->
<!-- staging.test: {STAGING_TEST} -->
<!-- staging.routes: {STAGING_ROUTES} -->
<!-- staging.health_path: {STAGING_HEALTH_PATH} -->

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

## TIER 0 — Deterministic Pre-Checks (no MCP needed)

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

## TIER 2 — Playwright Browser Checks (FULL_BROWSER mode only)

Only run Tier 2 when `TEST_MODE=FULL_BROWSER` and Playwright MCP tools are available.

First, verify Playwright MCP tools are available by calling `browser_snapshot`.
If Playwright MCP is not reachable, fall back to curl-based checks (see FALLBACK section below).

**Phase 1 — Infrastructure Health** (prefer API-driven):
- Use curl: `curl -sf {STAGING_URL}{STAGING_HEALTH_PATH}` — if 200, PASS without MCP.
- Only use `browser_navigate` + `browser_console_messages` if curl is not reachable.
- Check browser console messages for JS errors (one call).
- Report: PASS/FAIL

**Phase 2 — Browser Console Error Detection**:

```javascript
// batched browser_run_code call
async (page) => {
  await page.goto('{STAGING_URL}');
  // Collect any console errors
  const errors = [];
  page.on('console', msg => {
    if (msg.type() === 'error') errors.push(msg.text());
  });
  // Wait briefly for page load
  await page.waitForLoadState('networkidle').catch(() => {});
  return {
    pageLoaded: true,
    consoleErrors: errors,
    hasConsoleErrors: errors.length > 0,
  };
}
```

Report: PASS if no console errors, WARN if console errors detected (list them).

**Phase 3 — Route Coverage** (spot-check configured routes via browser):

Iterate over `staging.routes` and check each in a batched `browser_run_code` call:

```javascript
async (page) => {
  const baseUrl = '{STAGING_URL}';
  const routes = '{STAGING_ROUTES}'.split(',').map(r => r.trim());
  const results = {};
  for (const route of routes) {
    const resp = await page.request.get(`${baseUrl}${route}`);
    results[route] = resp.status();
  }
  return results;
}
```

Report each route: PASS (2xx/3xx) or FAIL (5xx or error).

---

## RESILIENCE

If Playwright cannot reach staging (navigation timeout, connection refused):
- Report: STAGING_UNREACHABLE with the specific error.
- Include: "Staging site unreachable. Check environment health manually. Deployment may still be in progress."
- Do NOT retry navigation.
- Do NOT take a screenshot of the error state (saves tokens).

If a staging bug is observed (unexpected error, broken UI, wrong data):
- Take a Playwright screenshot ONLY for specific bug evidence: `browser_take_screenshot`
  (filename: `.claude/screenshots/<bug-name>.png`)
- Include the screenshot filename in the report as evidence.
- Report the specific error pattern.

If test results are inconclusive (intermittent timeouts, partial page loads):
- Report as INCONCLUSIVE (not FAIL) with the `browser_run_code` result as evidence.
- Do NOT take a screenshot.
- Include: "Results inconclusive — staging may still be deploying or under load. Wait 5 minutes and re-run, or investigate manually."

## FALLBACK (if Playwright MCP not reachable)

Use curl commands:
- `curl -sf {STAGING_URL}{STAGING_HEALTH_PATH}` — health check
- For each route in `staging.routes`: `curl -sf {STAGING_URL}<route>` — route check

Report what can be verified via API only; mark browser-only checks as SKIPPED.

---

## Return

Return a structured summary:

```
- Test dispatch mode: Script / Prompt / Unrecognized extension fallback / Generic tiered
- Test mode: FULL_BROWSER / API_ONLY (with reason)
- Tier 0 (health + route scan): PASS/FAIL/WARN
- Tier 1 (API route checks): PASS/FAIL/SKIPPED
- Tier 2 Phase 1 (infrastructure health): PASS/FAIL/SKIPPED
- Tier 2 Phase 2 (console error detection): PASS/WARN/SKIPPED
- Tier 2 Phase 3 (route coverage): PASS/FAIL/SKIPPED
- Overall staging test: PASS/WARN/FAIL
  - WARN if TEST_MODE=API_ONLY (browser not tested)
  - WARN if console errors detected but no hard failures
  - FAIL if any Tier 0 health check failed or any Tier 2 phase FAIL
```

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
