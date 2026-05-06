# Generic Fallback Patterns (loaded by /dso:ui-discover steps when ADAPTER_FILE is empty)

**Trigger**: `ADAPTER_FILE` is empty — no stack adapter is configured for the project's stack/template-engine combination, and the Stack Adapter Resolution step at the top of SKILL.md emitted the `"WARNING: No stack adapter found ..."` log line.

When loaded, each step below uses heuristic patterns instead of the adapter's typed pattern fields. Heuristic-based discovery is best-effort and may miss edge cases — log warnings where appropriate.

## Component inventory (generic fallback)
*(loaded from Phase C Step 2)*

1. Use Grep with heuristic patterns to find component-like definitions:
   - Pattern: `export\s+(default\s+)?function\s+(\w+)` (React/Vue)
   - Pattern: `export\s+(default\s+)?class\s+(\w+)` (class components)
   - Pattern: `\{%[-\s]+macro\s+(\w+)\s*\(` (Jinja2-like)
   - Pattern: `<template>` (Vue SFC)
   - Search all UI files discovered in Phase C Step 1.

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

5. Write individual `components/<name>.json` files with full detail (see `docs/cache-format-reference.md` Section 6).

Each component entry's `dependsOn` in the manifest: its source file path.

## Route discovery (generic fallback)
*(loaded from Phase C Step 3)*

- Grep for common route patterns across all source files:
  - `@\w+\.(route|get|post|put|delete|patch)\s*\(\s*["']([^"']+)["']` (decorator-based)
  - `router\.(get|post|put|delete|patch)\s*\(\s*["']([^"']+)["']` (Express-like)
  - File-system routing: map file paths in `pages/` or `app/` directories to routes.
- Use heuristic template rendering detection:
  - `render_template\s*\(\s*["']([^"']+)["']`
  - `render\s*\(\s*["']([^"']+)["']`
- Warn that route detection may be incomplete without an adapter.

## App shell analysis (generic fallback)
*(loaded from Phase C Step 5)*

- Look for common layout files:
  - `**/base.html`, `**/layout.html` (template-based)
  - `**/layout.tsx`, `**/layout.jsx` (React/Next.js)
  - `**/_layout.svelte` (SvelteKit)
  - `**/__layout.vue` (Nuxt)
- Use heuristic patterns for inheritance/composition:
  - `\{%[-\s]+extends\s+` (Jinja2-like)
  - `export\s+default\s+function\s+.*Layout` (React)
- Warn that template inheritance analysis may be incomplete without an adapter.
