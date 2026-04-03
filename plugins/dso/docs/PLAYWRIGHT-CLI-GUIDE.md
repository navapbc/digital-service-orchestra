# @playwright/cli Usage Guide

> **When to read**: Before using `@playwright/cli` for browser automation in sub-agent contexts, CI pipelines, or any environment where Playwright MCP tools are unavailable.

## Pre-Flight Checks

Before invoking any `@playwright/cli` command, verify the CLI is available and browsers are installed:

```bash
# Check CLI availability
npx @playwright/cli --version

# Install if absent (pins to known-good version)
npm install @playwright/cli@0.1.1

# Install Chromium browser binary (required on fresh CI environments)
npx playwright install chromium
# With system dependencies (Linux/CI):
npx playwright install --with-deps chromium
```

**Version constraint**: Pin to `@playwright/cli@0.1.1`. This version is validated in the DSO spike (PASSED: 19 / FAILED: 0). Do not use `^0.1.1` — the package is alpha-channel and may introduce breaking changes in minor bumps.

---

## Command Reference

All commands are invoked as `npx @playwright/cli <subcommand> [options]`.

### open — Launch a browser session

```bash
npx @playwright/cli open -s=<session-name>
npx @playwright/cli open -s=<session-name> <url>
```

Opens a new browser session identified by `<session-name>`. Session state is stored under `.playwright-cli/`. A session **must be opened before `run-code`, `snapshot`, `screenshot`, `console`, `click`, `goto`, or `type`** can be used.

### close — Terminate a session

```bash
npx @playwright/cli close -s=<session-name>
```

Terminates the named session and releases associated browser resources.

### goto — Navigate to a URL

```bash
npx @playwright/cli goto -s=<session-name> <url>
```

Navigates the open session to `<url>`. Waits for the page to reach `load` state before returning.

### click — Click a page element

```bash
npx @playwright/cli click -s=<session-name> <selector>
```

Clicks the element matching `<selector>`. Selector syntax follows Playwright's locator syntax (CSS, text, ARIA role).

### hover — Hover over an element

```bash
npx @playwright/cli hover -s=<session-name> <selector>
```

### type — Type text into the focused element

```bash
npx @playwright/cli type -s=<session-name> <text>
```

### fill — Fill a form input

```bash
npx @playwright/cli fill -s=<session-name> <selector> <value>
```

Clears and fills `<selector>` with `<value>`. Preferred over `type` for form inputs.

### select — Select a dropdown option

```bash
npx @playwright/cli select -s=<session-name> <selector> <value>
```

### upload — Upload a file

```bash
npx @playwright/cli upload -s=<session-name> <selector> <file-path>
```

`<file-path>` must be within the worktree root (sandbox restriction). Use `$REPO_ROOT/.tmp/` for test fixtures (gitignored).

### snapshot — Capture accessibility tree

```bash
npx @playwright/cli snapshot -s=<session-name>
```

Outputs an accessibility tree as a YAML file saved to `.playwright-cli/page-<timestamp>.yml`. Use for non-visual structure inspection and element discovery.

### screenshot — Capture a PNG

```bash
npx @playwright/cli screenshot -s=<session-name> --filename=<path>
```

Saves a PNG to `<path>`. Path must be writable and within allowed roots. Recommended destination: `.claude/screenshots/<descriptive-name>.png` (gitignored).

### console — Read browser console messages

```bash
npx @playwright/cli console -s=<session-name>
```

Returns buffered console messages with level markers: `[LOG]`, `[WARNING]`, `[ERROR]`. Use after navigation or interactions to check for JS errors.

### run-code — Execute arbitrary Playwright code

```bash
npx @playwright/cli run-code -s=<session-name> '<async-function>'
```

Executes `<async-function>` in the context of the open session's page. This is the most flexible command — use it for assertions, DOM inspection, and actions not covered by other subcommands.

### eval — Evaluate a JavaScript expression

```bash
npx @playwright/cli eval -s=<session-name> '<expression>'
```

Evaluates a JavaScript expression in the page context and returns the result to stdout.

---

## Command Selection Reference

| Goal | Command | Notes |
|------|---------|-------|
| Inspect page structure | `snapshot` | Outputs accessibility tree (YAML); no pixels |
| Visual verification | `screenshot` | Outputs PNG; use sparingly (high cost) |
| Execute arbitrary Playwright logic | `run-code` | Most flexible; use for assertions, waits, complex interactions |
| Read console errors | `console` | Use after navigation/interaction |
| Fill a form field | `fill` | Preferred over `type` for inputs |
| Navigate to URL | `goto` | Waits for `load` state |
| Read DOM values | `eval` or `run-code` | `eval` for simple expressions; `run-code` for multi-step |

**Token cost guideline**: `snapshot` and `run-code` with targeted queries are lowest cost. `screenshot` should be used only when visual regression or pixel-level verification is required.

---

## run-code Patterns

### Required signature

The `run-code` argument **must** use the `async (page) => {}` signature. The `page` object is injected as the first argument — do not assume it is globally available.

```bash
# Correct
npx @playwright/cli run-code -s=my-session 'async (page) => { return await page.title(); }'

# Wrong: missing async, missing page parameter
npx @playwright/cli run-code -s=my-session 'page.title()'
```

### Return values vs console.log

Return values from `run-code` are written to stdout. `console.log()` inside the function is NOT surfaced as the return value — it goes to the browser's console buffer (readable via `console` subcommand).

```bash
# Correct: use return
npx @playwright/cli run-code -s=my-session 'async (page) => { return await page.title(); }'

# Wrong: console.log output is not captured in stdout
npx @playwright/cli run-code -s=my-session 'async (page) => { console.log(await page.title()); }'
```

### Loading HTML content

`file://` URLs are blocked by default. Use `page.setContent()` to inject HTML inline:

```bash
# Correct: inline HTML injection
npx @playwright/cli run-code -s=my-session 'async (page) => {
  await page.setContent("<h1>Test</h1>");
  return await page.locator("h1").textContent();
}'

# Wrong: file:// blocked without env flag
npx @playwright/cli run-code -s=my-session 'async (page) => {
  await page.goto("file:///path/to/fixture.html");
}'
```

If `file://` navigation is genuinely required, set `PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true` before invoking the command. This is the exception, not the default pattern.

### Batching multiple checks

Combine multiple checks into a single `run-code` call to reduce invocation overhead:

```bash
# Preferred: one call, structured return
npx @playwright/cli run-code -s=my-session 'async (page) => {
  return {
    title: await page.title(),
    url: page.url(),
    heading: await page.locator("h1").textContent(),
    status: await page.locator(".status").textContent()
  };
}'

# Avoid: four separate run-code calls for the same page
```

### Async DOM mutations and waits

```bash
npx @playwright/cli run-code -s=my-session 'async (page) => {
  await page.waitForSelector("[data-ready]", { state: "attached", timeout: 30000 });
  return await page.locator("[data-ready]").textContent();
}'
```

Both `waitForSelector` and `waitForLoadState` work correctly via `run-code`. Default timeout is 30 seconds — adjust via the `timeout` option for staging environments where LLM processing takes 30–120 seconds.

---

## Session Naming Conventions

Sessions are identified by the `-s=<name>` flag. Session state is persisted under `.playwright-cli/` by session name.

**Convention**: `-s=<skill-prefix>-<worktree-branch>-<timestamp>`

Examples:

```bash
-s=ui-discover-worktree-20260402-193626-1743630000
-s=playwright-debug-worktree-20260402-180620-1743630001
-s=e2e-smoke-worktree-20260402-193626-1743630002
```

**Rules**:
- Use a skill-recognizable prefix (e.g., `ui-discover`, `playwright-debug`, `e2e-smoke`).
- Include the worktree branch name so concurrent sessions across worktrees do not collide.
- Include a timestamp suffix to avoid collisions within the same worktree across runs.
- Session names are arbitrary strings — no special characters required, but hyphens are conventional.

**Session lifecycle**:
1. `open -s=<name>` — creates session; required before any other command.
2. Subsequent commands use `-s=<name>` to attach to the session.
3. `close -s=<name>` — terminates session; call in a `finally`-equivalent cleanup step.

Multiple concurrent sessions with distinct names work independently. A sub-agent can open a session, pass the session name back to the orchestrator, and a follow-on sub-agent can resume in the same browser without re-navigating.

---

## Disk-Based Output Patterns

`@playwright/cli` commands write results to stdout or disk files. Sub-agents read these outputs directly from the Bash tool return value or from disk.

### stdout output (run-code, eval, console)

```bash
# Capture stdout directly from Bash tool result
result=$(npx @playwright/cli run-code -s=my-session 'async (page) => { return await page.title(); }')
echo "$result"
```

The Bash tool return value contains the full stdout. Parse it as a string, JSON object, or line-delimited text depending on what the `run-code` function returns.

### File output (screenshot, snapshot)

```bash
# Screenshot: saved to specified path
npx @playwright/cli screenshot -s=my-session --filename=.claude/screenshots/home-page.png
# Verify: check file exists and is non-empty
test -s .claude/screenshots/home-page.png && echo "screenshot captured"

# Snapshot: saved to .playwright-cli/page-<timestamp>.yml
npx @playwright/cli snapshot -s=my-session
# Read the most recent snapshot file
ls -t .playwright-cli/page-*.yml | head -1 | xargs cat
```

### Output validation pattern

Always validate command output before treating it as authoritative:

```bash
# Pattern: run-code with structured return, then validate presence of expected fields
output=$(npx @playwright/cli run-code -s=my-session 'async (page) => {
  return { status: await page.locator(".status").textContent() };
}')

if echo "$output" | grep -q '"status"'; then
  echo "Status field present: $output"
else
  echo "ERROR: unexpected output — $output" >&2
  exit 1
fi
```

---

## CI Environment Considerations

### Browser installation

CI environments often lack pre-installed browser binaries. Always install Chromium before running commands:

```bash
# Minimal install (Chromium only)
npx playwright install chromium

# With system dependencies (required on Ubuntu/Debian runners)
npx playwright install --with-deps chromium
```

Cache the browser binary between CI runs to reduce cold-start time:
- Cache path: `~/.cache/ms-playwright`
- Also cache: `node_modules/` (or `spike-env/node_modules/` if using an isolated install directory)

### Sandbox restrictions

On Linux CI runners (no sandbox user namespace support), Chromium requires `--no-sandbox`:

```bash
PLAYWRIGHT_CHROMIUM_SANDBOX=0 npx @playwright/cli open -s=ci-test
```

Or set via environment variable in the CI job:

```yaml
env:
  PLAYWRIGHT_CHROMIUM_SANDBOX: "0"
```

### Headless mode

`@playwright/cli` runs in headless mode by default in non-interactive environments. No additional flags are needed for CI headless operation.

### file:// protocol

If tests require `file://` navigation (not recommended — use `page.setContent()` instead):

```bash
PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true npx @playwright/cli goto -s=ci-test file:///path/to/fixture.html
```

---

## Example Bash Invocations

### Full session lifecycle

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
SESSION="ui-verify-$(git branch --show-current)-$(date +%s)"

# 1. Open session and navigate
npx @playwright/cli open -s="$SESSION" https://localhost:3000

# 2. Inspect page structure
npx @playwright/cli snapshot -s="$SESSION"

# 3. Execute checks via run-code
page_state=$(npx @playwright/cli run-code -s="$SESSION" 'async (page) => {
  return {
    title: await page.title(),
    h1: await page.locator("h1").textContent()
  };
}')
echo "Page state: $page_state"

# 4. Capture screenshot for visual record
npx @playwright/cli screenshot -s="$SESSION" --filename="$REPO_ROOT/.claude/screenshots/verify-$(date +%s).png"

# 5. Check for console errors
npx @playwright/cli console -s="$SESSION"

# 6. Close session
npx @playwright/cli close -s="$SESSION"
```

### File upload via run-code

```bash
# Create test fixture inside worktree (.tmp/ is gitignored)
# (Use Write tool to create the file first)
FIXTURE="$REPO_ROOT/.tmp/test_policy.md"

SESSION="upload-test-$(date +%s)"
npx @playwright/cli open -s="$SESSION" https://localhost:3000/upload
npx @playwright/cli run-code -s="$SESSION" "async (page) => {
  await page.locator('input[type=\"file\"]').setInputFiles('$FIXTURE');
  await page.locator('button[type=\"submit\"]').click();
  await page.waitForSelector('.upload-success', { timeout: 30000 });
  return 'upload-ok';
}"
npx @playwright/cli close -s="$SESSION"
```

### Staging environment with extended timeouts

```bash
SESSION="staging-smoke-$(date +%s)"
npx @playwright/cli open -s="$SESSION" https://staging.example.com

# LLM processing steps take 30–120s — use waitForSelector with extended timeout
result=$(npx @playwright/cli run-code -s="$SESSION" 'async (page) => {
  await page.waitForSelector(".result-ready", { state: "visible", timeout: 120000 });
  return await page.locator(".result-ready").textContent();
}')
echo "Result: $result"
npx @playwright/cli close -s="$SESSION"
```

---

## Key Constraints

1. **Open before run-code**: A session must be created with `open` before any other subcommand can attach to it.
2. **`async (page) => {}` signature required**: The `run-code` argument must be an async function receiving `page` as its first argument.
3. **Return, not console.log**: Use `return` to surface values from `run-code`. `console.log` output goes to the browser console buffer, not stdout.
4. **`page.setContent()` over `file://`**: Load HTML inline via `page.setContent()` instead of `file://` URLs (blocked by default).
5. **File access sandbox**: File paths in `upload` and `setInputFiles` must be within the worktree root. Use `$REPO_ROOT/.tmp/` for fixtures.
6. **Version pin**: Use `@playwright/cli@0.1.1` exactly (alpha channel — no caret ranges).
7. **Session names are global within the process**: Use the naming convention (`<prefix>-<worktree>-<timestamp>`) to prevent collisions across concurrent sub-agents.

---

## Tiered Approach to Browser Automation

Always escalate through tiers rather than jumping to full browser interaction. See `/dso:playwright-debug` skill for the full protocol.

| Tier | Method | Cost | When to Use |
|------|--------|------|-------------|
| 0 | Deterministic: existing test suite | ~0 | First. Always run existing tests before interactive debugging. |
| 1 | Code analysis: read templates, routes, static files | Low | When Tier 0 fails. Inspect source to form hypotheses. |
| 2 | Targeted `run-code` checks | Medium | When Tier 1 needs runtime confirmation. Batch multiple checks. |
| 3 | Full session (`snapshot`, `click`, navigation) | High | Last resort. Only when Tier 2 cannot reproduce the issue. |
