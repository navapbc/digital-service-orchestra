---
name: playwright-debug
description: Use when debugging a UI or browser-visible bug. Enforces a 3-tier hypothesis-first process that minimizes Playwright MCP token usage by exhausting static code analysis and targeted JS evidence before escalating to full browser interaction.
user-invocable: true
allowed-tools: Read, Grep, Glob, Bash, browser_run_code, browser_snapshot, browser_navigate, browser_click, browser_hover, browser_take_screenshot, browser_console_messages, browser_wait_for
---

# Playwright Debug: 3-Tier Hypothesis-First Process

Structured browser debugging that reduces Playwright MCP token usage by 4x by generating hypotheses from code before opening a browser.

> **Token cost reference**: Full MCP session ~114k tokens. Targeted `browser_run_code` call ~8-12k tokens. Code-only analysis ~2-4k tokens. Resolve at the cheapest tier possible.

## When to Use

- A UI element is missing, wrong, or broken on a deployed or local environment
- A browser-visible feature is not behaving as expected
- Playwright MCP tests are failing and the root cause is unclear
- Debugging a rendering or routing issue before writing a fix

## When NOT to Use

- You already know the root cause from a failing unit test — fix it directly
- The bug is confirmed server-side (use logs or test output)
- You need to validate a full end-to-end deployment workflow

<!-- PROJECT-SPECIFIC: Load additional "When NOT to Use" guidance from reference file if configured -->

```bash
PLAYWRIGHT_DEBUG_REF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" skills.playwright_debug_reference 2>/dev/null || echo "")
```

If `PLAYWRIGHT_DEBUG_REF` is non-empty, read the `## When NOT to Use (Project-Specific)` section from that file for additional project-specific exclusions.

## Visual Regression Gate (run before Tier 1)

If visual regression baselines exist, run your project's visual regression test command first. This is a deterministic visual comparison against snapshots in `<project snapshot directory>`.

- **Pass**: No browser debugging needed — baselines confirm UI matches expectations.
- **Fail**: The diff output identifies which pages/elements changed. Use the failed elements as your Tier 2 targets (skip Tier 1 hypothesis generation — the diff IS the hypothesis). Start at Tier 2 with a single `browser_run_code` call checking visibility, position, and computed styles of the flagged elements.
- **No baselines**: Skip this gate and start at Tier 1 as normal.

If called from `/dso:sprint` post-batch: on visual verification failure, the orchestrator reverts the task to open. Save screenshots to `.claude/screenshots/` (gitignored).

---

## The 3-Tier Process

```
Tier 1 (Code Analysis) → Generate hypotheses from source code, templates, CSS, routes
  → [hypothesis explains bug conclusively] → Fix directly, no browser needed
  → [hypothesis needs confirmation] → Tier 2

Tier 2 (Targeted Evidence) → browser_run_code (batched JS) + scoped browser_snapshot
  → [evidence confirms hypothesis] → Fix directly
  → [evidence is inconclusive after ≤3 browser_run_code calls] → Tier 3

Tier 3 (Full MCP Interaction) → browser_navigate, browser_click, browser_hover, browser_take_screenshot
  → Fix based on observed behavior
```

**Never jump tiers.** Always complete Tier 1 before touching the browser. Always complete Tier 2 before using full MCP interaction.

---

## Tier 1: Code Analysis — Generate Hypotheses

**Tools**: Read, Grep, Glob (no browser tools)

**Goal**: Produce a ranked list of hypotheses about the bug's root cause, sourced entirely from reading code.

### Step 1: Identify the symptom's code path

<!-- PROJECT-SPECIFIC: Load symptom-to-code-path table from reference file if configured -->

```bash
PLAYWRIGHT_DEBUG_REF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" skills.playwright_debug_reference 2>/dev/null || echo "")
```

If `PLAYWRIGHT_DEBUG_REF` is non-empty, read the `## Symptom-to-Code-Path Table` section from that file for the project-specific symptom table.

**Generic fallback (when no reference file configured):**

Map the symptom to its source:

| Symptom type | Where to look first |
|---|---|
| Element not visible | Template or view layer, CSS class, JS `display:none` toggle |
| Wrong data displayed | Request handler → data layer → view variable |
| Form submit fails | `<form>` action/method, JS event handler, server route |
| JS error | Static JS source files, inline `<script>` blocks in templates |
| API response wrong | Route handler, serializer/formatter, data query |
| Redirect unexpected | Route return value, authentication middleware, prefix/base path |
| Styles not applied | Stylesheet load order, class name typo, selector specificity conflict |
| Interactive element unresponsive | Event listener binding, JS initialization timing, DOM ready state |
| Missing content | Conditional rendering logic, null/empty data guard, permissions check |
| Layout broken | CSS grid/flex parent, missing container class, responsive breakpoint |

### Step 2: Read the relevant code

<!-- PROJECT-SPECIFIC: Load code reading patterns from reference file if configured -->

```bash
PLAYWRIGHT_DEBUG_REF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" skills.playwright_debug_reference 2>/dev/null || echo "")
```

If `PLAYWRIGHT_DEBUG_REF` is non-empty, read the `## Code Reading Patterns` section from that file for project-specific Grep patterns and file locations.

**Generic fallback (when no reference file configured):**

Use Read and Grep to examine:

1. **Route handlers**: `Grep pattern="route\|handler\|endpoint\|controller" path="src/"` to find the relevant handler
2. **Templates/views**: Read the template or view file — look for conditionals, variable references, and inherited/included blocks
3. **CSS/JS**: Read static files if the symptom is visual — check `display`, `visibility`, `hidden` class toggling, event listener binding
4. **Data layer**: If data is wrong, trace the query or data fetch in `src/` (look for `db/`, `services/`, `models/`, `api/`)

### Step 3: Formulate ranked hypotheses

Write out 2-4 hypotheses ranked by likelihood. Format:

```
H1 (most likely): <brief description of what is wrong and why>
    <one sentence supporting evidence from code>
H2: <alternative explanation>
    <one sentence supporting evidence or reasoning>
H3: <lower-likelihood alternative>
    <one sentence supporting evidence or reasoning>
```

<!-- PROJECT-SPECIFIC: Load example hypotheses from reference file if configured -->

```bash
PLAYWRIGHT_DEBUG_REF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" skills.playwright_debug_reference 2>/dev/null || echo "")
```

If `PLAYWRIGHT_DEBUG_REF` is non-empty, read the `## Example Hypotheses` section from that file for project-specific worked hypothesis examples.

**Generic fallback (when no reference file configured):**

Example format for a button visibility bug:

```
H1 (most likely): The button is absent from the DOM because a server-side conditional
    renders it only when a certain data value is truthy, and that value is falsy at runtime.
H2: The button is in the DOM but hidden via CSS — a class toggle or computed style
    has `display: none` or `visibility: hidden` that is not cleared.
H3: A JS error on page load prevents the initialization code from running, so the
    button's event handler or show/hide logic never executes.
```

### Escalation criteria from Tier 1

- **Stay in Tier 1** if you can trace the bug conclusively from source code (e.g., a conditional that always evaluates false, a missing CSS class, a typo in a route path)
- **Escalate to Tier 2** if the bug requires knowing runtime state (what value does the variable actually have? Is the JS event binding firing?) that cannot be determined from static analysis alone

---

## Tier 2: Targeted Evidence Collection

**Tools**: `browser_run_code` (batched JS), `browser_snapshot` (scoped)

**Goal**: Collect the minimum evidence needed to confirm or refute the top hypotheses. Budget: **at most 3 `browser_run_code` calls** before deciding to fix or escalate to Tier 3.

### Batching principle

Each `browser_run_code` call should test multiple hypotheses simultaneously. Do NOT make one call per hypothesis.

**Anti-pattern (multiple separate calls, high token cost):**
```javascript
// Call 1 — tests only one thing
async (page) => document.querySelector('#primary-action') !== null

// Call 2 — tests only one thing
async (page) => getComputedStyle(document.querySelector('#primary-action')).display

// Call 3 — tests only one thing
async (page) => document.querySelector('form[data-action]') !== null
```

**Preferred pattern (1 batched call, ~10k tokens):**
```javascript
async (page) => {
  const btn = document.querySelector('#primary-action');
  const form = document.querySelector('form[data-action]');
  return {
    btnExists: btn !== null,
    btnDisplay: btn ? getComputedStyle(btn).display : 'element missing',
    btnHidden: btn ? btn.classList.contains('hidden') : null,
    formExists: form !== null,
    formAction: form ? form.getAttribute('data-action') : null,
    itemCount: document.querySelectorAll('[data-item-id]').length,
    pageTitle: document.title,
  };
}
```

<!-- PROJECT-SPECIFIC: Load Tier 2 evidence examples from reference file if configured -->

```bash
PLAYWRIGHT_DEBUG_REF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" skills.playwright_debug_reference 2>/dev/null || echo "")
```

If `PLAYWRIGHT_DEBUG_REF` is non-empty, read the `## Tier 2 Evidence Examples` section from that file for project-specific batched JS examples using real selectors.

**Generic fallback (when no reference file configured):**

Use the batched pattern shown above directly. Replace `#primary-action`, `form[data-action]`, and `[data-item-id]` with your project's actual element selectors — the structure and multi-hypothesis batching principle remain the same regardless of framework.

### Scoped `browser_snapshot` usage

Use `browser_snapshot` only when you need DOM structure, not computed state. Pass a CSS selector scope to avoid dumping the entire page:

```
# Full-page snapshot: ~30k tokens
browser_snapshot()

# Scoped to a container: ~2-3k tokens
browser_snapshot(selector=".main-content")
```

Use scoped snapshots to check element hierarchy, ARIA roles, or ref IDs needed for Tier 3 clicks.

### Checking console errors

After navigating, always check for JS errors before forming conclusions:

```
browser_console_messages(level: "error")
```

A JS exception can silently disable event handlers and is missed by DOM inspection alone.

### Escalation criteria from Tier 2

- **Fix and stop** if a `browser_run_code` result confirms a hypothesis that has a clear code fix
- **Escalate to Tier 3** if after 3 `browser_run_code` calls the evidence is still inconclusive — this means the bug requires interactive behavior (hover state, animation, multi-step form submission, race condition visible only during interaction)
- **Never spend more than 3 `browser_run_code` calls at Tier 2** — escalate rather than loop

---

## Tier 3: Full MCP Interaction

**Authorized when**: Tier 2 evidence is inconclusive after the 3-call budget, OR the bug is interactive by nature (drag-and-drop, hover tooltip, multi-step wizard, timing-sensitive).

**Tools**: `browser_navigate`, `browser_click`, `browser_hover`, `browser_take_screenshot`, `browser_wait_for`, `browser_console_messages`

### Sequence

1. **Navigate** to the page under test:
   ```
   browser_navigate(url: "<your-app-url>/page-to-debug")
   ```

2. **Check console errors immediately** after navigation:
   ```
   browser_console_messages(level: "error")
   ```

3. **Reproduce the bug** interactively — follow the user's reported steps exactly

4. **Capture evidence** at the point of failure:
   ```
   browser_take_screenshot(filename: ".claude/screenshots/playwright-debug-<timestamp>.png")
   ```
   Save screenshots to `.claude/screenshots/` (gitignored). Never save to `/tmp/` or repo root.

5. **Inspect DOM at failure point** with a scoped snapshot:
   ```
   browser_snapshot(selector="<narrowest relevant container>")
   ```

<!-- PROJECT-SPECIFIC: Load framework-specific Tier 3 constraints from reference file if configured -->

```bash
PLAYWRIGHT_DEBUG_REF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" skills.playwright_debug_reference 2>/dev/null || echo "")
```

If `PLAYWRIGHT_DEBUG_REF` is non-empty, read the `## Framework-Specific Constraints` section from that file for project-specific Tier 3 interaction patterns (e.g., file upload handling, custom widget interaction).

<!-- PROJECT-SPECIFIC: Load staging/environment configuration from reference file if configured -->

```bash
PLAYWRIGHT_DEBUG_REF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" skills.playwright_debug_reference 2>/dev/null || echo "")
```

If `PLAYWRIGHT_DEBUG_REF` is non-empty, read the `## Staging Configuration` section from that file for environment-specific URLs, timeouts, and wait conditions.

**Generic fallback for timeouts (when no reference file configured):**

If the target environment runs async processing or slow operations, use `browser_wait_for` with an appropriate timeout:

```
browser_wait_for(text: "<expected completion text>", time: 30)
```

The default 5s timeout may be insufficient for operations involving network calls, background processing, or heavy computation.

### Screenshot rule

`browser_take_screenshot` is for final visual confirmation only — not for intermediate inspection. Use `browser_snapshot` (text, tokenized) for all intermediate DOM inspection. A screenshot at the wrong time during a long Tier 3 session contributes ~5-8k tokens of image data.

---

## Token Budget Summary

| Action | Approximate token cost | When to use |
|---|---|---|
| Tier 1: Read/Grep/Glob | ~2-4k | Always start here |
| `browser_run_code` (batched) | ~8-12k | Tier 2 only, max 3 calls |
| `browser_snapshot` (scoped) | ~2-5k | Tier 2/3 for DOM structure |
| `browser_snapshot` (full page) | ~25-35k | Avoid — use scoped instead |
| `browser_navigate` | ~3-5k | Tier 3 |
| `browser_click` / `browser_hover` | ~3-5k each | Tier 3 only |
| `browser_take_screenshot` | ~5-8k (image) | Tier 3 final confirmation only |

**Session total by tier:**
- Tier 1 only: ~4k
- Tier 1 + Tier 2: ~20-30k
- Tier 1 + Tier 2 + Tier 3: ~50-70k
- Full MCP without discipline: ~114k

---

<!-- PROJECT-SPECIFIC: Load worked example from reference file if configured -->

```bash
PLAYWRIGHT_DEBUG_REF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" skills.playwright_debug_reference 2>/dev/null || echo "")
```

If `PLAYWRIGHT_DEBUG_REF` is non-empty, read the `## Worked Example` section from that file for a project-specific end-to-end debugging walkthrough using real routes, selectors, and data shapes.

**Generic fallback (when no reference file configured):**

**Scenario**: A "Submit" button on a form page is not visible after login.

**Tier 1 — Code analysis:**
- Grep for the button's selector in templates: `Grep pattern="submit\|btn-submit\|type=\"submit\"" path="src/"`
- Read the template — find a conditional: `{% if user.can_submit %}` wrapping the button
- Grep for `can_submit` in the data layer: it's a property on `User` that returns `False` when `user.status != "active"`
- **H1**: Button is absent from DOM because `user.can_submit` returns `False` for the current test user (status `"pending"`).
- **H2**: Button exists but has `display: none` from a CSS class applied server-side.

**Tier 1 verdict**: H1 is conclusively traceable from code. No browser needed — fix the test user's status or the conditional logic.

**If H1 were inconclusive, Tier 2 would be:**
```javascript
async (page) => {
  const btn = document.querySelector('[type="submit"]');
  const form = document.querySelector('form');
  return {
    btnExists: btn !== null,
    btnDisplay: btn ? getComputedStyle(btn).display : 'element missing',
    btnDisabled: btn ? btn.disabled : null,
    formExists: form !== null,
    userStatusBadge: document.querySelector('[data-user-status]')?.textContent ?? null,
  };
}
```

**Tier 2 verdict**: If `btnExists: false`, H1 confirmed — fix the conditional. If `btnExists: true, btnDisplay: "none"`, H2 confirmed — fix the CSS. If both are present and enabled, escalate to Tier 3 to check JS event handler binding.

---

## Reference

For browser interaction patterns, sandbox restrictions, and timeout guidance, see `${CLAUDE_PLUGIN_ROOT}/docs/PLAYWRIGHT-MCP-GUIDE.md`.

---

## Quick Decision Card

```
Start: What is the symptom?
  ↓
Tier 1: Read templates, routes, CSS, JS — write hypotheses
  ↓
Can you conclusively explain the bug from code alone?
  → YES: Fix it. Done.
  → NO: Tier 2

Tier 2: One batched browser_run_code (test all hypotheses at once)
  ↓
Does the evidence confirm a hypothesis?
  → YES: Fix it. Done.
  → NO: Another call (max 3 total)
  → Still inconclusive after 3 calls: Tier 3

Tier 3: Navigate → reproduce → screenshot at failure point → snapshot scoped DOM
  ↓
Fix based on observed behavior.
```
