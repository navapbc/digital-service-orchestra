# Playwright MCP Usage Guide

> **When to read**: Before using Playwright MCP browser tools (`browser_click`, `browser_snapshot`, `browser_file_upload`, `browser_run_code`, etc.) for interactive testing or staging validation.

## File Upload (INC-030)

The upload page uses a hidden `<input type="file">` behind a visible `.dropzone` div. Three common mistakes and how to avoid them:

### Do NOT: Click the file input directly
```
browser_click(ref=<file-input-ref>)  # FAILS: timeout, element intercepted by dropzone
```

### Do NOT: Use browser_file_upload without a file chooser dialog
```
browser_file_upload(paths=[...])  # FAILS: "no related modal state" unless a dialog is open
```

### Do NOT: Reference files in /tmp/
```
page.locator('input[type="file"]').setInputFiles('/tmp/test.md')
# FAILS: "File access denied: outside allowed roots"
```

### DO: Create files in the worktree, then use setInputFiles

```bash
# Step 1: Create test file inside worktree (use Write tool)
# Path: $REPO_ROOT/.tmp/test_policy.md  (.tmp/ is gitignored)
```

```javascript
// Step 2: Upload via browser_run_code
async (page) => {
  await page.locator('input[type="file"]').setInputFiles(
    '<REPO_ROOT>/.tmp/test_policy.md'
  );
}
```

`setInputFiles` programmatically sets files on the input element — no click or file chooser needed.

### Alternative: Click the dropzone (not the input) to trigger file chooser

```javascript
// Step 1: Click the DROPZONE overlay to open file chooser
async (page) => { await page.locator('.dropzone').click(); }
// Step 2: Then use browser_file_upload with a file inside allowed roots
browser_file_upload(paths=['<REPO_ROOT>/.tmp/test_policy.md'])
```

## File Path Sandbox

Playwright MCP restricts file access to the worktree root. Always:
- Create test fixtures in `$REPO_ROOT/.tmp/` (gitignored)
- Never use `/tmp/`, `/var/`, or other system paths
- Use absolute paths (resolve `$REPO_ROOT` via `git rev-parse --show-toplevel`)

## Screenshots

Always save Playwright screenshots to `.claude/screenshots/` (gitignored) to avoid cluttering the repo root:

```
browser_take_screenshot(filename: ".claude/screenshots/descriptive-name.png")
```

Design-specific screenshots go in their design directory instead: `designs/<uuid>/screenshots/`.

## Timeouts

- Default Playwright action timeout is 5s — too short for staging (LLM processing takes 30-120s)
- Use `browser_wait_for` with `time: 120` for processing steps
- Use `browser_wait_for` with `text: "complete"` for status polling

## Console Errors

After each navigation, check for JS errors:
```
browser_console_messages(level: "error")
```

## API-Driven Alternative

For upload testing that doesn't need to exercise the browser UI, use the Playwright request API directly (no DOM interaction):
```javascript
async (page) => {
  const response = await page.request.post(`${baseUrl}/upload`, {
    multipart: {
      file: {
        name: 'test_policy.md',
        mimeType: 'text/markdown',
        buffer: Buffer.from('# Test Policy\n\nApplicants must be 18+.\n'),
      }
    }
  });
  return response.status();
}
```

This matches how the pytest E2E tests work (`test_upload_flow.py`).

## Tiered Approach to Playwright MCP

Always escalate through tiers rather than jumping to full MCP interaction. See `/playwright-debug` skill for the full protocol.

| Tier | Method | Token Cost | When to Use |
|------|--------|------------|-------------|
| 0 | Deterministic: `make test-visual` + `make test-e2e` | ~0 | First. Always run existing tests before interactive debugging. |
| 1 | Code analysis: read templates, routes, static files | ~2-5k | When Tier 0 fails. Inspect source to form hypotheses. |
| 2 | Targeted `browser_run_code` | ~5-15k | When Tier 1 needs runtime confirmation. Batch multiple checks into one call. |
| 3 | Full MCP (`browser_snapshot`, `browser_click`, etc.) | ~30-100k+ | Last resort. Only when Tier 2 cannot reproduce the issue. |

**Target**: Most debugging sessions should resolve at Tier 0-1 (~16k tokens vs ~114k baseline).

## Visual Regression Testing

Visual regression uses Python Playwright `page.screenshot()` + `PIL.ImageChops` for pixel-level comparison. Python Playwright does NOT support `to_have_screenshot()` — use the PIL approach instead.

### Running Tests
```bash
make test-visual           # Run visual regression tests
make test-visual-update    # Update baseline snapshots
```

### Infrastructure
- **Baselines**: `app/tests/e2e/snapshots/` (committed to git)
- **Helpers**: `app/tests/e2e/visual_helpers.py` (screenshot capture, PIL comparison, diff generation)
- **Pages tested**: home, upload, results, review
- **Styleguide**: Debug-only `/styleguide` route renders Jinja2 component partials (status-badge, stat-card, alert-banner, outcome-tag) with fixture data for component-level visual regression

### Writing a Visual Regression Test
```python
from tests.e2e.visual_helpers import take_screenshot, compare_screenshots

def test_home_page_visual(page, live_server):
    page.goto(live_server.url("/"))
    screenshot = take_screenshot(page, "home")
    assert compare_screenshots(screenshot, "home"), "Visual regression detected"
```

## Token Optimization Patterns

### Scoped Snapshots
Avoid full-page `browser_snapshot` when you only need a specific element:
```javascript
// Anti-pattern: full page snapshot (~10k tokens)
browser_snapshot()

// Preferred: targeted element snapshot
browser_snapshot({ ref: "<specific-element-ref>" })
```

### browser_run_code Batching

Batch multiple checks into a single `browser_run_code` call:

```javascript
// Anti-pattern: 4 sequential calls (~8k tokens)
browser_run_code("async (page) => { return await page.title(); }")
browser_run_code("async (page) => { return await page.url(); }")
browser_run_code("async (page) => { return await page.locator('h1').textContent(); }")
browser_run_code("async (page) => { return await page.locator('.status').textContent(); }")

// Preferred: 1 batched call (~2k tokens)
browser_run_code(`async (page) => {
  return {
    title: await page.title(),
    url: page.url(),
    heading: await page.locator('h1').textContent(),
    status: await page.locator('.status').textContent(),
  };
}`)
```

### Screenshot Discipline
- Use `browser_take_screenshot` only when visual verification is needed
- For text content checks, use `browser_run_code` to extract text instead
- Save screenshots to `.claude/screenshots/` (gitignored)
