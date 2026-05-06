# Phase 3: Selective Regeneration (loaded by /dso:ui-discover when cache exists with selective staleness)

**Trigger**: Phase B Step 2 cache assessment identified specific stale entries (subset of files changed), OR `--refresh` mode is used with a valid cache. If the cache is missing or wholly stale, Phase C (Full Discovery) handles regeneration instead.

Acquire the lock (skip if already acquired in Phase B Step 2):
```
bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh acquire
```
If it exits non-zero, another instance is running — **stop**.

## Step 1: Categorize staleness scope

Using the stale entry list from Phase B Step 2 (or the full entry list if `--refresh`) plus the manifest's `dependsOn` graph, categorize the refresh scope:

| Scope | Trigger | What's stale |
|-------|---------|-------------|
| `theme-global` | Theme/style config files changed | All route visual data (DOM, screenshots, patterns). Template structure remains valid. |
| `shell-global` | Base layout or nav template changed | App shell + all route snapshots (layout may have changed everywhere). |
| `component-only` | Component/macro template files changed | Affected component entries + any route entries that use those components. |
| `route-partial` | Only page template files changed | Only the affected route snapshot entries. |

Multiple scopes can apply simultaneously (e.g., a component changed AND a theme file changed).

## Step 2: Regenerate stale entries only

For each stale entry, re-run only the relevant Phase C step logic:

- **Stale components** → Re-run Phase C Step 2 logic for only the affected source files. Update `components/<name>.json` and the corresponding `_index.json` entry.
- **Stale design tokens** → Re-run Phase C Step 4 to re-extract tokens from the changed CSS/SCSS files. Update `global/design-tokens.json`.
- **Stale app shell** → Re-run Phase C Step 5 to re-analyze the base layout template. Update `global/app-shell.json`.
- **Stale routes** → Re-run Phase C Steps 6–7 for only the affected routes. If Playwright is available and the app is running, re-crawl just those routes. Update the corresponding `routes/<slug>.json` and screenshot files.

After regenerating stale entries:

1. Recompute `uiFileHashes` for all changed source files.
2. Update `gitCommit` to current HEAD.
3. Update `generatedAt` timestamp.
4. Set all regenerated entries to `valid: true`.
5. Regenerate `validate-ui-cache.sh` (since the embedded commit and dependency graph changed).

## Step 3: Report refresh summary

Present a summary showing:

- Scope(s) detected.
- Entries regenerated vs. entries preserved (count and names).
- Changed source files that triggered the refresh.
- Whether Playwright re-crawl was performed.
- Total time/effort saved vs. a full generation.

**Release lock:**
```
bash ${CLAUDE_PLUGIN_ROOT}/skills/ui-discover/lock.sh release
```
