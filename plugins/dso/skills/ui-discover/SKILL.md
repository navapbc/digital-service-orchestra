---
name: ui-discover
description: >
  Generates or refreshes the UI Discovery Cache for a project. Inventories
  components via Glob/Grep, crawls routes via Playwright, and writes
  structured results to .ui-discovery-cache/. Produces a deterministic
  validation script for git-based cache invalidation. Run once before
  starting an epic's wireframe designs.
argument-hint: [--refresh | --validate-only]
allowed-tools: Read, Glob, Grep, Write, Edit, Bash, Task, AskUserQuestion
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:ui-discover cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# UI Discovery Cache Agent

You are a UI Discovery specialist. Your task is to generate or refresh the
`.ui-discovery-cache/` directory for this project, producing structured JSON
files that the `design-wireframe` skill consumes to avoid redundant Playwright
crawls and component inventory scans.

Read [docs/cache-format-reference.md](docs/cache-format-reference.md) for the
complete JSON schemas. Read [templates/manifest-template.json](templates/manifest-template.json)
for a populated manifest example.

## Stack Adapter Resolution

This skill uses a **config-driven stack adapter** for component discovery instead
of hardcoding framework-specific patterns. The adapter provides glob patterns,
regex patterns, and framework detection rules for the project's web stack.

### Resolve the adapter at skill startup:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
ADAPTER_FILE=$(bash ".claude/scripts/dso resolve-stack-adapter.sh")
```

### Adapter loaded vs missing:

- **If `ADAPTER_FILE` is set**: Load the adapter YAML. Use its
  `component_file_patterns.glob_patterns` for component file discovery,
  `component_file_patterns.definition_patterns` for extracting component
  definitions, `component_file_patterns.import_patterns` for finding imports,
  `component_file_patterns.exclude_patterns` for file exclusion,
  `route_patterns` for route and blueprint discovery,
  `template_syntax` for template inheritance and block analysis, and
  `framework_detection` for framework sniffing. All subsequent references to
  "component globs", "definition patterns", "import patterns", "exclude
  patterns", "route patterns", "template syntax", and "framework detection"
  in this skill resolve from the loaded adapter config.

- **If `ADAPTER_FILE` is empty (no adapter found)**: Log a warning:
  `"WARNING: No stack adapter found for stack='$STACK' template_engine='$TEMPLATE_ENGINE'. Falling back to generic file discovery."` Proceed with generic file discovery
  patterns (broad globs like `**/*.html`, `**/*.tsx`, `**/*.jsx`, `**/*.vue`).
  Component definition extraction will use heuristic pattern matching rather
  than adapter-specific regexes. Route discovery will use broad decorator
  patterns (`@\w+\.(route|get|post)\s*\(`). Framework detection will scan for
  common framework names in dependency files.

Store the resolved adapter data (or null) as `ADAPTER` for use in subsequent
phases. The adapter is a pure-data YAML file — no code execution is needed.

---

## Modes

Determine mode from `$ARGUMENTS`:

| Argument | Mode | Behavior |
|----------|------|----------|
| *(empty)* | Auto | Full generation if no cache exists; validate + selective refresh if cache exists |
| `--refresh` | Force refresh | Run incremental refresh even if cache appears valid |
| `--validate-only` | Validate | Run validation script, report status, exit |

---

## Phase 0: Local Environment Preflight (/dso:ui-discover)

### Step 0: Verify local environment (/dso:ui-discover)

Before any discovery work, verify that the local development stack is running.
The Playwright crawl (Phase 2 Step 8) requires Docker, Postgres, and the
application to be healthy.

```
.claude/scripts/dso check-local-env.sh
```

Where `$REPO_ROOT` is determined by `git rev-parse --show-toplevel`.

**If the script exits 0**: all checks passed — proceed to Phase 1.

**If the script exits non-zero**: the output identifies which layer failed
(Docker, Postgres, app container, or health check). Use AskUserQuestion to
present the failure and ask whether to:
- "Fix and retry" (user starts missing services, then re-run the check)
- "Continue without live app" (skip Playwright crawl; static analysis only)
- "Stop" (halt the skill)

If the user chooses "Continue without live app", set `playwrightUsed = false`
and skip Step 8 (Playwright route crawl) in Phase 2. All other phases proceed
normally with static-analysis-only data.

---

## Phase 1: Environment Detection & Cache Assessment (/dso:ui-discover)

### Step 1: Detect environment (/dso:ui-discover)

Gather project context by running these checks:

**Git commit:**
```
git rev-parse --short HEAD 2>/dev/null
```
If git is not available, **stop**. Inform the user that git is required for
cache invalidation and the skill cannot proceed.

**Playwright CLI (`@playwright/cli`):**
```
command -v npx >/dev/null 2>&1 && npx @playwright/cli --version 2>/dev/null
```
Note whether the `@playwright/cli` binary is available. If the command exits
non-zero or is not found, warn that route crawling will be skipped and the cache
will be static-analysis-only.

**Running application:** If Phase 0 passed, the app is confirmed healthy on its
port. Use the port from `.claude/scripts/dso check-local-env.sh` output or the `APP_PORT` env var
(default port depends on the framework — use the adapter's conventions or
fall back to common defaults: 5000 for Flask, 3000 for Node, 8080 for Go).
If Phase 0 was skipped with "Continue without live app", skip this probe
entirely.

**Project context:**
- Read `.claude/design-notes.md` if it exists — look for app URL hints, framework info,
  and design system references.
- Detect the framework using the adapter's `framework_detection` config:
  - Read each file listed in `framework_detection.marker_files`
  - Check for matches against `framework_detection.marker_keys` entries
  - Record the detected framework name

  **If no adapter is loaded (generic fallback):** Scan `pyproject.toml`,
  `requirements.txt`, `package.json`, `go.mod`, or `Gemfile` for common
  framework names. Report the detected framework or "unknown" if none found.

### Step 2: Assess existing cache (/dso:ui-discover)

Check for `.ui-discovery-cache/manifest.json`.

**If found:**
1. Read the manifest and verify it parses as valid JSON. If corrupt, warn the
   user, delete the cache directory, and proceed to Phase 2 (full generation).
2. Check for `.ui-discovery-cache/validate-ui-cache.sh`. If missing, treat as corrupt
   cache — warn and proceed to Phase 2.
3. Run: `bash .ui-discovery-cache/validate-ui-cache.sh`
4. Parse the single-line JSON output:
   - `{"status":"valid"}` — Report cache is current. If mode is Auto or
     Validate-only, **exit with summary**. If mode is Force refresh, proceed
     to Phase 3.
   - `{"status":"stale",...}` — Collect the `staleEntries` and `scope` from the
     output. Proceed to Phase 3 (selective regeneration).
   - `{"status":"error",...}` — Warn user. Delete cache and proceed to Phase 2
     (full generation).
5. Run the lock acquisition script (see Lock Protocol below):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh acquire
   ```
   If it exits non-zero, another instance is running. Report the PID from
   its output and **stop** — do not proceed or ask the user to override.

**If not found:**
- If mode is Validate-only, report "No cache exists" and exit.
- Otherwise, proceed to Phase 2 (full generation).

**If mode is Validate-only:** After running validation, report the result and
exit. Do not generate or refresh anything.

---

## Phase 2: Full Discovery (/dso:ui-discover)

Acquire the lock (skip if already acquired in Phase 1 Step 2):
```
bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh acquire
```
If it exits non-zero, another instance is running — **stop**.

Create the cache directory structure:
```
mkdir -p .ui-discovery-cache/global .ui-discovery-cache/components .ui-discovery-cache/routes .ui-discovery-cache/screenshots
```

### Step 3: Discover UI file inventory (/dso:ui-discover)

Use Glob to find all UI files. Use the adapter's `component_file_patterns.glob_patterns`
if available, otherwise use these generic patterns:

```
**/*.html
**/*.css
**/*.scss
**/*.js
**/*.tsx
**/*.jsx
**/*.vue
**/*.svelte
```

**Exclude** files matching the adapter's `component_file_patterns.exclude_patterns`
if available, otherwise use these generic exclusions:
- `**/node_modules/**`
- `**/.venv/**`
- `**/htmlcov/**`
- `**/__pycache__/**`
- `**/*.test.*`, `**/*.spec.*`, `**/__tests__/**`
- `**/dist/**`, `**/build/**`

For each discovered file, compute its SHA-256 hash:
```
sha256sum <file> | cut -d' ' -f1
```

Store the results as the `uiFileHashes` map (path -> `sha256:<hash>`).

If **no UI files are found**, stop. Inform the user that no UI files were
detected. Use AskUserQuestion to offer custom glob patterns or confirm the
project structure.

### Step 4: Component inventory (/dso:ui-discover)

Discover and analyze all component definitions across template/source files
using the adapter's patterns.

**If adapter is loaded:**

1. Use Grep with the adapter's `component_file_patterns.definition_patterns`
   to find all component definitions across files matching the adapter's
   `component_file_patterns.glob_patterns`:
   - Each definition pattern includes a regex and capture group descriptions
   - Search paths are derived from the adapter's glob patterns

2. For each component definition found, use Grep and Read to extract:
   - **Component name**: from the capture group designated in the pattern
   - **Parameters/Props**: from the parameter capture group in the definition pattern
   - **Default values**: from parameter defaults in the definition signature
   - **Purpose**: infer from component name, comments, and rendered content
   - **Related components**: other components referenced within the same body
   - **File path**: the source file containing the component

3. Map import/include directives using the adapter's
   `component_file_patterns.import_patterns` to build the component dependency
   graph. Each import pattern specifies the regex and its capture groups.

**If no adapter is loaded (generic fallback):**

1. Use Grep with heuristic patterns to find component-like definitions:
   - Pattern: `export\s+(default\s+)?function\s+(\w+)` (React/Vue)
   - Pattern: `export\s+(default\s+)?class\s+(\w+)` (class components)
   - Pattern: `\{%[-\s]+macro\s+(\w+)\s*\(` (Jinja2-like)
   - Pattern: `<template>` (Vue SFC)
   - Search all UI files discovered in Step 3

2. Extract component metadata using best-effort heuristic parsing.

3. Map import directives with generic patterns:
   - `import\s+.*\s+from\s+["']([^"']+)["']` (JS/TS imports)
   - `\{%[-\s]+import\s+["']([^"']+)["']` (template imports)
   - `\{%[-\s]+include\s+["']([^"']+)["']` (template includes)

4. Write `components/_index.json` — flat catalog array:
   ```json
   [
     { "name": "component_name", "path": "path/to/component.html", "parameters": ["param1", "param2"], "purpose": "Description" }
   ]
   ```

5. Write individual `components/<name>.json` files with full detail (see
   cache-format-reference.md Section 6).

Each component entry's `dependsOn` in the manifest: its source file path.

### Step 5: Route discovery (/dso:ui-discover)

Detect routes and map them to templates/components using the adapter's
`route_patterns` config.

**If adapter is loaded:**

**Blueprint/router detection:**
- Grep using the adapter's `route_patterns.registration_patterns` in all
  source files under `src/`:
  - Each pattern includes a regex and capture group descriptions
  - Extract the router/blueprint name from the designated capture group

**Route detection:**
- Grep using the adapter's `route_patterns.decorator_patterns` in all source
  files under `src/`:
  - Each pattern specifies the regex for matching route declarations
  - Capture groups identify the HTTP method and URL path

**Template/component mapping:**
- For each route function body, grep using the adapter's
  `route_patterns.template_render_patterns` to map route paths to the
  template files or components they render
- Record the rendered template/component alongside the route path

**Blueprint/router registration:**
- Read entry point files (e.g., `app.py`, `__init__.py`, `main.ts`) for
  registration patterns from the adapter's `route_patterns.registration_patterns`
- Map router variable names to their URL prefixes if applicable

**If no adapter is loaded (generic fallback):**

- Grep for common route patterns across all source files:
  - `@\w+\.(route|get|post|put|delete|patch)\s*\(\s*["']([^"']+)["']` (decorator-based)
  - `router\.(get|post|put|delete|patch)\s*\(\s*["']([^"']+)["']` (Express-like)
  - File-system routing: map file paths in `pages/` or `app/` directories to routes
- Use heuristic template rendering detection:
  - `render_template\s*\(\s*["']([^"']+)["']`
  - `render\s*\(\s*["']([^"']+)["']`
- Warn that route detection may be incomplete without an adapter

For each discovered route:
1. Record the route path, HTTP methods, router/blueprint name, source file, and
   template/component file (if any)
2. Note URL parameters (e.g., `<job_id>`, `<int:id>`, `:id`, `[id]`)
3. Record the source file path for dependency tracking

Write `global/route-map.json` with the framework name and route map (see
cache-format-reference.md Section 4).

**Fallback:**
- If route detection is inconclusive, use AskUserQuestion to ask the user
  for the routing approach and route list.

If the number of discovered routes exceeds 50, warn the user. Use
AskUserQuestion to ask whether to crawl all routes or select a subset.

### Step 6: Theme & design token extraction (/dso:ui-discover)

Detect and parse theme configuration files:

1. **Tailwind CSS**: If `tailwind.config.*` exists, read it — extract
   `theme.extend.colors`, `theme.extend.spacing`, `theme.extend.fontSize`,
   `theme.extend.boxShadow`, `theme.extend.borderRadius`. Resolve all values
   to concrete units.

2. **CSS custom properties**: Scan all `.css` files under `src/templates/`,
   `src/static/`, and `static/`. Grep for `--` custom property definitions
   (pattern: `--[\w-]+\s*:\s*[^;]+`). Resolve color values to hex.

3. **SCSS variables**: If `.scss` files exist, grep for `$variable:` definitions
   and extract color, spacing, and typography tokens.

4. **USWDS design tokens**: If the project uses USWDS (U.S. Web Design System),
   check for `uswds` in `static/` directory or CSS imports. Note the USWDS
   version if detectable.

5. Resolve all values to concrete units:
   - Colors -> hex (`#RRGGBB`)
   - Spacing -> px
   - Typography -> `size/line-height, weight`
   - Shadows -> CSS `box-shadow` value
   - Radii -> px

Write `global/design-tokens.json` (see cache-format-reference.md Section 3).

The design-tokens entry's `dependsOn` in the manifest: all theme/style config
files parsed.

### Step 7: App shell analysis (/dso:ui-discover)

Find the root layout template/component for the application using the adapter's
`template_syntax` config.

**If adapter is loaded:**

- Use the adapter's `template_syntax.inheritance_pattern` to find templates
  that extend a base layout (e.g., `{% extends "base.html" %}` for Jinja2)
- Use the adapter's `template_syntax.block_patterns` to find overridable
  content regions in the base layout
- Use the adapter's `template_syntax.include_patterns` to map template
  composition and partial includes
- Look for the base template by finding templates that do NOT match the
  inheritance pattern (i.e., root templates that are not extending another)

**If no adapter is loaded (generic fallback):**

- Look for common layout files:
  - `**/base.html`, `**/layout.html` (template-based)
  - `**/layout.tsx`, `**/layout.jsx` (React/Next.js)
  - `**/_layout.svelte` (SvelteKit)
  - `**/__layout.vue` (Nuxt)
- Use heuristic patterns for inheritance/composition:
  - `\{%[-\s]+extends\s+` (Jinja2-like)
  - `export\s+default\s+function\s+.*Layout` (React)
- Warn that template inheritance analysis may be incomplete without an adapter

Read the base template and extract:
- **Layout pattern**: the top-level structural arrangement (e.g., `TopNav-Main-Footer`)
- **Block regions**: all overridable content regions — record the block name
  and its position in the layout
- **Navigation structure**: nav elements, their items, nesting, and any
  dynamic content references
- **Shared chrome**: persistent elements — header, footer, sidebar, breadcrumbs

Map the template inheritance chain:
- Grep all templates using the adapter's `template_syntax.inheritance_pattern`
  (or generic fallback) to identify which templates extend the base layout
- Record the inheritance chain for each discovered page template

Write `global/app-shell.json` (see cache-format-reference.md Section 2).

The app-shell entry's `dependsOn` in the manifest: root layout file (`base.html`
or equivalent) + any included partial templates.

### Step 8: Playwright route crawl (conditional) (/dso:ui-discover)

**If `@playwright/cli` is available AND the app is running:**

Use the `@playwright/cli` to crawl each route via discrete CLI commands. The
CLI uses named sessions (`-s=<name>`) to persist browser state across separate
Bash invocations.

**Open a session** (with cleanup trap to prevent orphaned Chrome on interruption):
```bash
# Register cleanup trap before opening — ensures browser is closed on exit/error/interruption
_pw_cleanup() { npx @playwright/cli close -s=ui-discover 2>/dev/null || true; }
trap _pw_cleanup EXIT TERM INT

npx @playwright/cli open -s=ui-discover
```

**For each route** in `.ui-discovery-cache/global/route-map.json`:

1. **Slugify** the route path per the Route Slug Convention in
   `docs/cache-format-reference.md` Section 1 (strip leading `/`, replace `/`
   with `_`, replace `:param` with `[param]`, root `/` becomes `_root`).

2. **Navigate** to the route URL:
   ```bash
   npx @playwright/cli goto -s=ui-discover "${APP_URL}${route_path}"
   ```

3. **Wait for network idle** using `run-code`:
   ```bash
   npx @playwright/cli run-code -s=ui-discover "async (page) => {
     await page.waitForLoadState('networkidle', { timeout: 30000 });
     return 'idle';
   }"
   ```

4. **Take a screenshot**:
   ```bash
   npx @playwright/cli screenshot -s=ui-discover \
     --filename=".ui-discovery-cache/screenshots/${slug}.png"
   ```

5. **Extract 3-level DOM summary** via `run-code`:
   ```bash
   npx @playwright/cli run-code -s=ui-discover "async (page) => {
     function summarize(el, depth) {
       if (depth > 3) return null;
       return {
         tag: el.tagName,
         id: el.id || null,
         classes: Array.from(el.classList).slice(0, 5),
         role: el.getAttribute('aria-role') || el.getAttribute('role') || null,
         text: (el.textContent || '').trim().slice(0, 100),
         children: Array.from(el.children).map(c => summarize(c, depth + 1)).filter(Boolean)
       };
     }
     return JSON.stringify(summarize(document.body, 0));
   }"
   ```

6. **Collect component-like elements** (elements with `data-component` attrs or
   class name patterns matching macro/component names) via `run-code`.

7. **Record the result**: parse the JSON output from `run-code` and store it
   under the route path key with `crawled: true`, `screenshot` path, and `dom`
   summary. On failure (non-zero exit), record `crawled: false` with the error
   message.

For parameterized routes (containing URL parameters in any format — `<param>`,
`:param`, `[param]`, etc.), generate reasonable test values: use `1` for
integer parameters, `test` for string parameters. If a parameterized route
fails to load, warn and skip — mark `playwrightCrawled: false` for that route.

Handle route navigation timeouts individually — log a warning for the timed-out
route and continue with remaining routes.

**Close the session:**
```bash
npx @playwright/cli close -s=ui-discover
```

**If Playwright is unavailable or the app is not running:**

Warn the user. Set `playwrightUsed: false` in the manifest. Route snapshots
will contain only static-analysis data (no DOM structure, no screenshots, no
observed prop values).

### Step 9: Write route snapshot files (/dso:ui-discover)

For each discovered route, combine all available data into a denormalized
snapshot:

1. **Static analysis** (always available): source file, rendered template,
   router/blueprint name, layout pattern (inferred from template inheritance)

2. **Playwright data** (if available): DOM summary + structure, layout
   description, screenshot path

3. **Denormalized component detail**: for each component used on the route's
   template (detected via the adapter's `component_file_patterns.import_patterns`
   or generic fallback), inline the full component data (parameters, purpose,
   available defaults) from the component inventory. This duplication is
   intentional — it allows a wireframe agent to load a single route file and
   have everything it needs.

Write `routes/<slug>.json` for each route (see cache-format-reference.md
Section 7).

Each route entry's `dependsOn` in the manifest: the template file + all
imported component files + theme files (if Playwright visual data is included).

### Step 10: Assemble manifest and validation script (/dso:ui-discover)

**Write manifest.json:**
- `version`: 1
- `generatedAt`: current ISO 8601 timestamp
- `gitCommit`: short SHA from Step 1
- `appUrl`: discovered app URL or null
- `playwrightUsed`: boolean from Step 8
- `uiFileHashes`: complete hash map from Step 3
- `entries`: dependency graph for every cache file written in Steps 4-9

Reference [templates/manifest-template.json](templates/manifest-template.json)
for the exact structure.

**Generate validate-ui-cache.sh:**

Write `.ui-discovery-cache/validate-ui-cache.sh` — a self-contained bash script that
implements the validation logic described in the Validation Script section below.

The script must embed:
- The `CACHED_COMMIT` value (git short SHA at generation time)
- The complete `DEPENDS_ON` graph (entry -> file list)
- The UI file include patterns and exclusion patterns
- The list of theme files (for scope detection)
- The root layout files (for scope detection)

**Update .gitignore:**

Check if the target project has a `.gitignore` file. If so, check whether
`.ui-discovery-cache/screenshots/` is already listed. If not, append it:
```
# UI Discovery Cache screenshots (environment-specific)
.ui-discovery-cache/screenshots/
```

**Release lock:**
```
bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh release
```

**Report completion summary:**
- Number of components inventoried
- Number of routes discovered
- Whether Playwright was used
- Total cache files written
- How to validate: `bash .ui-discovery-cache/validate-ui-cache.sh`
- How to use: run `/dso:preplanning` on the story — `dso:ui-designer` will load the cached discovery data to generate design artifacts

---

## Phase 3: Selective Regeneration (/dso:ui-discover)

Runs when validation (Step 2) identifies specific stale entries, or when
`--refresh` mode is used with a valid cache.

Acquire the lock (skip if already acquired in Phase 1 Step 2):
```
bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh acquire
```
If it exits non-zero, another instance is running — **stop**.

### Step 11: Categorize staleness scope (/dso:ui-discover)

Using the stale entry list from Step 2 (or the full entry list if `--refresh`)
plus the manifest's `dependsOn` graph, categorize the refresh scope:

| Scope | Trigger | What's stale |
|-------|---------|-------------|
| `theme-global` | Theme/style config files changed | All route visual data (DOM, screenshots, patterns). Template structure remains valid. |
| `shell-global` | Base layout or nav template changed | App shell + all route snapshots (layout may have changed everywhere). |
| `component-only` | Component/macro template files changed | Affected component entries + any route entries that use those components. |
| `route-partial` | Only page template files changed | Only the affected route snapshot entries. |

Multiple scopes can apply simultaneously (e.g., a component changed AND a theme
file changed).

### Step 12: Regenerate stale entries only (/dso:ui-discover)

For each stale entry, re-run only the relevant Step logic:

- **Stale components** -> Re-run Step 4 logic for only the affected
  source files. Update `components/<name>.json` and the corresponding
  `_index.json` entry.

- **Stale design tokens** -> Re-run Step 6 to re-extract tokens from the changed
  CSS/SCSS files. Update `global/design-tokens.json`.

- **Stale app shell** -> Re-run Step 7 to re-analyze the base layout template.
  Update `global/app-shell.json`.

- **Stale routes** -> Re-run Steps 8-9 for only the affected routes. If
  Playwright is available and the app is running, re-crawl just those routes.
  Update the corresponding `routes/<slug>.json` and screenshot files.

After regenerating stale entries:
1. Recompute `uiFileHashes` for all changed source files
2. Update `gitCommit` to current HEAD
3. Update `generatedAt` timestamp
4. Set all regenerated entries to `valid: true`
5. Regenerate `validate-ui-cache.sh` (since the embedded commit and dependency graph changed)

### Step 13: Report refresh summary (/dso:ui-discover)

Present a summary showing:
- Scope(s) detected
- Entries regenerated vs. entries preserved (count and names)
- Changed source files that triggered the refresh
- Whether Playwright re-crawl was performed
- Total time/effort saved vs. a full generation

**Release lock:**
```
bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh release
```

---

## Lock Protocol

The lock script at `${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh`
prevents concurrent `/dso:ui-discover` runs from corrupting the cache. It uses
`mkdir` for atomic lock acquisition (race-free on all filesystems) and records
the owning PID for stale-lock detection.

| Command | Behavior |
|---------|----------|
| `lock.sh acquire` | Atomic mkdir; if lock exists, checks PID liveness. Exits 0 on success, 1 if another live instance holds the lock. |
| `lock.sh release` | Removes lock dir. Only succeeds if current PID owns it (or `--force`). |
| `lock.sh release --force` | Unconditional removal — for manual recovery from crashed sessions. |
| `lock.sh status` | Prints lock holder PID and age; exits 0 if locked, 1 if unlocked. |

**IMPORTANT**: Always release the lock in your cleanup path. If the skill
errors out or is interrupted, the lock's stale-PID detection will allow the
next run to reclaim it automatically.

---

## Validation Script (`validate-ui-cache.sh`)

Generated by Step 10 and written to `.ui-discovery-cache/validate-ui-cache.sh`. This
script is self-contained, deterministic, and read-only.

### Requirements

- **Self-contained**: The `dependsOn` graph and UI file patterns are embedded
  directly in the script (not read from manifest.json at runtime).
- **Read-only**: Never modifies cache files. Only reports status.
- **Minimal dependencies**: Requires only `git` and `bash` (no `jq`).
- **JSON output**: Single-line JSON to stdout for easy parsing.
- **Exit codes**: 0 = success (valid or stale), 1 = error (cache unusable).

### Logic Flow

Generate the script by copying `.claude/scripts/dso validate-ui-cache.sh` and
substituting placeholder values (`<SHORT_SHA>`, `<LIST_OF_THEME_FILES>`, etc.) with
real values from the current cache state. Run validation with:

```bash
bash .claude/scripts/dso validate-ui-cache.sh
```

Every time the cache is refreshed, `validate-ui-cache.sh` is regenerated with the
updated commit, hashes, and dependency graph.

---

## Error Handling

| Condition | Action |
|-----------|--------|
| Git not available | **Stop.** Inform user that git is required for cache invalidation. |
| No UI files found | **Stop.** Inform user. Offer custom glob patterns via AskUserQuestion. |
| Playwright unavailable | Warn. Continue static-analysis-only. Set `playwrightUsed: false` in manifest. |
| App not running | Warn. Continue static-analysis-only. Set `playwrightUsed: false` in manifest. |
| Parameterized route can't crawl | Warn for that route. Set `playwrightCrawled: false` on the route snapshot. Continue with remaining routes. |
| manifest.json corrupt | Warn. Delete cache directory and run full generation. |
| Individual cache file corrupt | Mark entry stale. Regenerate just that entry. |
| Cached commit not in git history | Full generation needed (commit likely rebased away). |
| Route navigation timeout | Log warning for that route. Continue with remaining routes. |
| Too many routes (>50) | Warn user. AskUserQuestion: crawl all routes or select a subset? |
| Concurrent run detected (lock.sh fails) | **Stop.** Report the owning PID. User can force-release with `bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh release --force`. |
| validate-ui-cache.sh missing | Treat as corrupt cache. Recommend full regeneration. |
| No stack adapter found | Warn. Proceed with generic patterns. Note in manifest that adapter-specific detection was not used. |
