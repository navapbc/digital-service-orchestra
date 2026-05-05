---
name: ui-discover
description: >
  Use when starting an epic's wireframe designs, scanning a frontend for
  UI components, cataloguing existing routes, or inventorying frontend
  state. Generates or refreshes the UI Discovery Cache: inventories
  components via Glob/Grep, crawls routes via Playwright, and writes
  structured results to .ui-discovery-cache/. Produces a deterministic
  validation script for git-based cache invalidation. Trigger phrases
  include 'scan UI components', 'discover routes', 'catalog UI elements',
  'inventory frontend components', 'refresh ui-discovery-cache', 'before
  designing wireframes'.
argument-hint: [--refresh | --validate-only]
allowed-tools: Read, Glob, Grep, Write, Edit, Bash, Task, AskUserQuestion
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:ui-discover requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# UI Discovery Cache Agent

You are a UI Discovery specialist. Your task is to generate or refresh the
`.ui-discovery-cache/` directory for this project, producing structured JSON
files that the `ui-designer` agent consumes to avoid redundant Playwright
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

## Phase A: Local Environment Preflight (/dso:ui-discover)

### Step 1: Verify local environment (/dso:ui-discover)

Before any discovery work, verify that the local development stack is running.
The Playwright crawl (Phase C Step 6) requires Docker, Postgres, and the
application to be healthy.

```
.claude/scripts/dso check-local-env.sh
```

Where `$REPO_ROOT` is determined by `git rev-parse --show-toplevel`.

**If the script exits 0**: all checks passed — proceed to Phase B.

**If the script exits non-zero**: the output identifies which layer failed
(Docker, Postgres, app container, or health check). Use AskUserQuestion to
present the failure and ask whether to:
- "Fix and retry" (user starts missing services, then re-run the check)
- "Continue without live app" (skip Playwright crawl; static analysis only)
- "Stop" (halt the skill)

If the user chooses "Continue without live app", set `playwrightUsed = false`
and skip Phase C Step 6 (Playwright route crawl). All other phases proceed
normally with static-analysis-only data.

---

## Phase B: Environment Detection & Cache Assessment (/dso:ui-discover)

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

**Running application:** If Phase A passed, the app is confirmed healthy on its
port. Use the port from `.claude/scripts/dso check-local-env.sh` output or the `APP_PORT` env var
(default port depends on the framework — use the adapter's conventions or
fall back to common defaults: 5000 for Flask, 3000 for Node, 8080 for Go).
If Phase A was skipped with "Continue without live app", skip this probe
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
   user, delete the cache directory, and proceed to Phase C (full generation).
2. Check for `.ui-discovery-cache/validate-ui-cache.sh`. If missing, treat as corrupt
   cache — warn and proceed to Phase C.
3. Run: `bash .ui-discovery-cache/validate-ui-cache.sh`
4. Parse the single-line JSON output:
   - `{"status":"valid"}` — Report cache is current. If mode is Auto or
     Validate-only, **exit with summary**. If mode is Force refresh, proceed
     to Phase D.
   - `{"status":"stale",...}` — Collect the `staleEntries` and `scope` from the
     output. Proceed to Phase D (selective regeneration).
   - `{"status":"error",...}` — Warn user. Delete cache and proceed to Phase C
     (full generation).
5. Run the lock acquisition script (see Lock Protocol below):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh acquire
   ```
   If it exits non-zero, another instance is running. Report the PID from
   its output and **stop** — do not proceed or ask the user to override.

**If not found:**
- If mode is Validate-only, report "No cache exists" and exit.
- Otherwise, proceed to Phase C (full generation).

**If mode is Validate-only:** After running validation, report the result and
exit. Do not generate or refresh anything.

---

## Phase C: Full Discovery (/dso:ui-discover)

Acquire the lock (skip if already acquired in Phase B Step 2):
```
bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh acquire
```
If it exits non-zero, another instance is running — **stop**.

Create the cache directory structure:
```
mkdir -p .ui-discovery-cache/global .ui-discovery-cache/components .ui-discovery-cache/routes .ui-discovery-cache/screenshots
```

### Step 1: Discover UI file inventory (/dso:ui-discover)

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

### Step 2: Component inventory (/dso:ui-discover)

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

**If no adapter is loaded (generic fallback)**: load `${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/prompts/generic-fallback-patterns.md` and follow the **Component inventory (generic fallback)** section. It supplies heuristic component-definition patterns, generic import patterns, the `components/_index.json` catalog format, and the `dependsOn` rule.

### Step 3: Route discovery (/dso:ui-discover)

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

**If no adapter is loaded (generic fallback)**: load `${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/prompts/generic-fallback-patterns.md` and follow the **Route discovery (generic fallback)** section. It supplies decorator-based, router-based, file-system-routing, and heuristic template-rendering patterns.

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

### Step 4: Theme & design token extraction (/dso:ui-discover)

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

### Step 5: App shell analysis (/dso:ui-discover)

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

**If no adapter is loaded (generic fallback)**: load `${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/prompts/generic-fallback-patterns.md` and follow the **App shell analysis (generic fallback)** section. It supplies common layout-file globs and heuristic inheritance/composition patterns across template engines.

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

### Step 6: Playwright route crawl (conditional) (/dso:ui-discover)

**Skip condition**: if `playwrightUsed = false` (set by Phase A Step 1 when the user chose "Continue without live app", or by the `@playwright/cli unavailable` / `app not running` paths), skip this step entirely and proceed to Phase C Step 7.

**If `@playwright/cli` is available AND the app is running:**

Use the `@playwright/cli` to crawl each route via discrete CLI commands. The CLI uses named sessions (`-s=<name>`) to persist browser state across separate Bash invocations. Acquire and release the Playwright session lock per Lock Protocol below.

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

### Step 7: Write route snapshot files (/dso:ui-discover)

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

### Step 8: Assemble manifest and validation script (/dso:ui-discover)

**Write manifest.json:**
- `version`: 1
- `generatedAt`: current ISO 8601 timestamp
- `gitCommit`: short SHA from Phase B Step 1
- `appUrl`: discovered app URL or null
- `playwrightUsed`: boolean from Phase C Step 6
- `uiFileHashes`: complete hash map from Phase C Step 1
- `entries`: dependency graph for every cache file written in Phase C Steps 2–7

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

## Phase D: Selective Regeneration (branch — partial cache staleness only)

**Trigger**: Phase B Step 2 cache assessment identified specific stale entries (subset of files changed), OR `--refresh` mode is used with a valid cache. If the cache is missing or wholly stale, Phase C (Full Discovery) runs instead.

**Load**: `${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/phases/3-selective-regeneration.md` and follow it. Phase D Steps 1–3 categorize the staleness scope (`theme-global` / `shell-global` / `component-only` / `route-partial`), regenerate only the affected entries by re-running the relevant Phase C step logic (Phase C Step 2 for components, Phase C Step 4 for design tokens, Phase C Step 5 for app shell, Phase C Steps 6–7 for routes), update `uiFileHashes` / `gitCommit` / `generatedAt` and regenerate `validate-ui-cache.sh`, and report the refresh summary. Lock acquisition + release per Lock Protocol below.

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

Generated by Phase C Step 8 and written to `.ui-discovery-cache/validate-ui-cache.sh`. This
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
