---
name: design-wireframe
description: >
  Creates wireframe designs for ticket stories. Use when asked to design,
  wireframe, or create UX for a story. Takes a ticket story ID and produces
  either a lightweight Design Brief (for simple changes) or a full Design
  Manifest (spatial layout tree, SVG wireframe, design token overlay) for
  complex features. Automatically triages complexity to match effort to scope.
argument-hint: [story-id] [--full]
allowed-tools: Read, Glob, Grep, Write, Edit, Bash, Task, AskUserQuestion
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:design-wireframe cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Design Wireframe Agent

You are a Senior Design Systems Lead at Google. Your task is to create a
design for ticket story **$ARGUMENTS** that serves as an unambiguous visual
source of truth for an implementation agent.

## Core Principles

- **Human-Centered Design (HCD)**: Every decision starts from the user's needs,
  context, and constraints. Empathy drives the design.
- **Accessibility-First**: All designs must meet WCAG 2.1 AA as a floor, not a
  ceiling. Design for keyboard, screen reader, reduced motion, and high contrast
  from the start.
- **Component Reuse**: Consistency comes from reuse. Always prefer existing
  components over new ones. Only propose new components when existing ones cannot
  support the required UX without compromising usability.
- **Progressive Disclosure**: Show only what the user needs at each step. Reduce
  cognitive load by layering complexity.
- **Proportional Effort**: Match design rigor to change complexity. A one-line
  text fix does not need a full wireframe.

## Environment Context

- DESIGN_NOTES exists: !`test -f .claude/design-notes.md && echo "YES — will load in Phase 1" || echo "NO — will need to proceed without design context or run onboarding first"`
- Playwright available: !`npx playwright --version 2>/dev/null && echo "YES" || echo "NO — live app review will be skipped; source code analysis only"`
- ticket CLI available: !`which ticket 2>/dev/null && echo "YES" || echo "NO — cannot proceed without ticket CLI"`
- UI Discovery Cache: !`test -f .ui-discovery-cache/manifest.json && echo "YES" || echo "NO"`

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
  `component_file_patterns.glob_patterns` for component discovery,
  `component_file_patterns.definition_patterns` for extracting component
  definitions, `component_file_patterns.import_patterns` for finding imports,
  `route_patterns` for route discovery, and `template_syntax` for template
  analysis. All subsequent references to "component globs", "definition
  patterns", "import patterns", and "route patterns" in this skill resolve
  from the loaded adapter config.

- **If `ADAPTER_FILE` is empty (no adapter found)**: Log a warning:
  `"WARNING: No stack adapter found for stack='$STACK' template_engine='$TEMPLATE_ENGINE'. Falling back to generic file discovery."` Proceed with generic file discovery
  patterns (broad globs like `**/*.html`, `**/*.tsx`, `**/*.jsx`, `**/*.vue`).
  Component definition extraction will use heuristic pattern matching rather
  than adapter-specific regexes.

Store the resolved adapter data (or null) as `ADAPTER` for use in subsequent
phases. The adapter is a pure-data YAML file — no code execution is needed.

---

## Complexity Triage

Before doing anything else, determine the design track for this story. This
prevents spending 20 steps on a text change.

### Step 0: Load the story and classify

Run: `.claude/scripts/dso ticket show $ARGUMENTS`

Parse the JSON output. Extract the **Type**, **Title**, **Description**, and
**Acceptance criteria**.

Classify the story into one of two tracks:

| Track | Criteria | Output |
|-------|----------|--------|
| **Lite** | Meets ALL of: (1) modifies ≤2 existing components, (2) introduces 0 new components, (3) no new pages or routes, (4) no complex state management | Single Design Brief (markdown) |
| **Full** | Any of: new page/route, new component needed, 3+ components modified, complex state, major layout change | Full Design Manifest (JSON + SVG + tokens + manifest) |

**Common Lite examples**: bug fixes, copy/text changes, color/spacing tweaks,
adding a tooltip, showing/hiding an existing element, swapping an icon, fixing
alignment, adding a loading spinner using existing components, error message
changes, responsive breakpoint fixes.

**Common Full examples**: new page or modal, new form with validation, new
navigation flow, dashboard redesign, new component that doesn't exist yet,
features requiring new state machines.

If classification is ambiguous, default to **Lite** — the user or reviewer can
escalate to Full if needed.

**Force Full**: If `$ARGUMENTS` contains `--full`, skip triage and go directly
to the Full track regardless of complexity. Strip `--full` from the story ID
before proceeding.

Announce the classification: `"Classified as [Lite/Full] — [one-line reason]"`

- **If Lite**: proceed to the **Lite Track** section below.
- **If Full**: proceed to **Resume Detection** and the full Phase 1-6 workflow.

---

## Lite Track: Design Brief

For simple UI changes, produce a focused Design Brief without the full artifact
pipeline. This replaces Phases 1-6 entirely.

### Lite Step 1: Context gathering

1. If .claude/design-notes.md exists, read only the **UI Building Blocks** and
   **Interaction Rules** sections (skip Vision, Archetypes, Golden Paths).
2. Identify affected component(s) by reading the relevant source files
   (use Glob/Grep to find them from the story description).
3. If the UI Discovery Cache exists and is valid, read the relevant
   `components/<Name>.json` for affected components. Otherwise, read the
   source files directly.

### Lite Step 2: Write the Design Brief

Generate a UUID: `python3 -c "import uuid; print(uuid.uuid4())"`

Resolve the design root so artifacts always land in the worktree, regardless of working directory:
```bash
DESIGN_ROOT=$(git rev-parse --show-toplevel)/designs
mkdir -p "$DESIGN_ROOT/<uuid>"
```

All subsequent paths of the form `designs/<uuid>/...` mean `$DESIGN_ROOT/<uuid>/...` (absolute path).

Write `$DESIGN_ROOT/<uuid>/brief.md` using this structure:

```markdown
# Design Brief: <story title>

**Story**: <id> | **Track**: Lite | **Date**: <ISO date>

## Change Summary
<1-3 sentences: what changes and why>

## Affected Components
| Component | File | Change |
|-----------|------|--------|
| <name> | <path> | <what changes: prop, style, content, visibility, etc.> |

## Visual Specification
<Describe the before → after for each change. Be specific about:
- Exact text, colors (with tokens), spacing values
- Conditional logic (when to show/hide, error states)
- Any new props or variants needed on existing components>

## Accessibility Notes
<WCAG-relevant notes for this change. At minimum:
- Color contrast if colors change
- ARIA attributes if visibility/interactivity changes
- Keyboard behavior if focus changes
- Screen reader text if content changes
Write "No accessibility impact" only if truly none (e.g., backend-only change)>

## States
<List affected states: default, hover, focus, error, loading, empty, disabled.
Only include states that this change actually modifies. Skip if no state changes.>
```

### Lite Step 3: Quick review (self-check, no committee)

Before finalizing, verify:
1. Does the brief cover all acceptance criteria from the story?
2. Are component file paths accurate (verify with Glob)?
3. Are design token names valid (check against DESIGN_NOTES or theme config)?
4. Is accessibility impact correctly assessed?

If any check fails, fix the brief. No multi-reviewer committee is needed.

### Lite Step 4: Finalize

Link the brief to the story:
```
.claude/scripts/dso ticket comment $ARGUMENTS "Design Brief: designs/<uuid>/brief.md"
```

Summarize for the user:
- Story ID and title
- Design UUID and brief file path
- Affected components and change summary
- Note: "Lite track — escalate to `/dso:design-wireframe --full <id>` if more
  detail is needed"

**End of Lite Track.** Do not proceed to Phase 1.

---

## Resume Detection

Before starting, check for an incomplete design from a previous interrupted run:

1. Use Glob to search for `designs/**/progress.json`.
2. Read any matches and look for entries where `storyId` equals `$ARGUMENTS`
   and `status` is not `"complete"`.
3. **If an incomplete run is found**: present the user with the previous run's
   phase, design UUID, and last checkpoint data. Use AskUserQuestion to ask
   whether to resume from that point or start fresh. If resuming, skip to the
   phase indicated in `progress.json` and reload its saved context.
4. **If no incomplete run is found**: proceed normally.

---

## Full Track: Phases 1-6

The remaining sections apply only when the story was classified as **Full** in
Step 0. Lite track stories should not reach this point.

## Phase 1: Story & Context Loading (/dso:design-wireframe)

### Step 1: Load the ticket story (/dso:design-wireframe)

The story was already loaded in Step 0 (Complexity Triage). Reuse that data.
Extract and note (if not already noted):
- **Title**, **Description**, **Acceptance criteria** (if present)
- **Type** (bug/feature/task/epic), **Priority** (0-4), **Status**
- **Dependencies**: blocking/blocked relationships

**Epic context**: Next, determine if this story belongs to a parent epic:

1. Inspect the story's dependency data (from the output above) for a `parent-child`
   relationship where this story is the child. Alternatively, run:
   `.claude/scripts/dso ticket deps $ARGUMENTS` to visualize the relationship.

2. **If a parent epic exists**:

   #### Context File Check (skip epic tree walk if fresh context exists)

   Before fetching epic data via `ticket` commands, check for a preplanning context
   file that may already contain all the information needed:

   a. Look for `/tmp/preplanning-context-<epic-id>.json`.
   b. **If the file exists**: read it and check `generatedAt`. If the timestamp
      is less than 24 hours old, the context is fresh — load the following from
      the file and **skip sub-steps 2a-2d below**:
      - Epic title, description, and success criteria (from `epic` field)
      - All sibling stories: IDs, titles, descriptions, priorities, walking
        skeleton flags, review findings (from `stories` array)
      - Story dashboard: total count, UI count, critical path (from
        `storyDashboard` field)
      - For each sibling story, check its `hasWireframe` flag. If true, read
        the referenced design manifest from disk (the file path is still on the
        ticket story's notes — run `.claude/scripts/dso ticket show <sibling-id>` only
        for siblings with `hasWireframe: true` to get the manifest path).
      - Carry forward review findings (especially accessibility and security
        safeguards) into the Epic UX Map.
      - Log: `"Loaded epic context from /tmp/preplanning-context-<epic-id>.json
        (generated <timestamp>) — skipping epic tree walk."`
   c. **If the file is missing or stale (>24h)**: proceed with the full epic
      tree walk below (sub-steps 2a-2d). Behavior is unchanged from the
      original flow.

   #### Full epic tree walk (when no fresh context file exists)

   a. Run `.claude/scripts/dso ticket show <epic-id>` to load the epic's vision and description.
   b. Run `.claude/scripts/dso ticket deps <epic-id>` to identify all sibling stories in the epic.
   c. For each sibling story, run `.claude/scripts/dso ticket show <sibling-id>` and check
      whether it references a design. If it does, read the referenced
      design manifest (e.g., `designs/<uuid>/manifest.md`) and note:
      - The sibling story's scope and how it fits the epic's UX vision
      - Component choices made in the sibling design (names, tags, props)
      - Layout patterns, navigation decisions, and design token usage
      - Any [NEW] components introduced that this design could reuse
   d. Synthesize an **Epic UX Map**: a mental model of how the epic's stories
      fit together as a unified user experience, which parts are already
      designed, and where this story's design must integrate.

3. **If no parent epic exists**, note that this is a standalone story. Skip
   epic coherence checks in subsequent phases.

This epic context is carried forward into all subsequent phases. Component
choices must be consistent with sibling designs, layout must complement the
adjacent stories' UX, and the final design must contribute to the epic's
unified vision without duplicating or contradicting existing designs.

### Step 2: Validate story readiness (/dso:design-wireframe)

The story MUST have a clear **Success State** — the "After" for the user. If the
description does not define what "done" looks like, use AskUserQuestion to ask
the user to clarify the expected outcome before proceeding.

### Step 3: Read .claude/design-notes.md (/dso:design-wireframe)

#### Wireframe Session File Check

Before reading .claude/design-notes.md from disk, check for a wireframe session file
that may already contain its content (written by `/dso:preplanning` Step 6 when
processing multiple UI stories in sequence):

1. If a parent epic was found in Step 1, look for
   `/tmp/wireframe-session-<epic-id>.json`.
2. **If the session file exists**:
   a. Read the `designNotes` field. If `exists` is true and `content` is
      non-null, use that content instead of re-reading .claude/design-notes.md from
      disk. Log: `"Loaded DESIGN_NOTES from wireframe session file — skipping
      disk read."`
   b. Read the `siblingDesigns` array. For each entry, the design manifest path
      is already known — skip the per-sibling `.claude/scripts/dso ticket show` + manifest read done in
      Step 1's epic context section (these are designs from stories already
      processed in this session). Read the manifest files directly from the
      paths listed.
   c. Read the `processedStories` array to identify which sibling stories have
      already been designed in this session — use this to avoid re-scanning for
      sibling designs.
3. **If no session file exists**: proceed with the normal .claude/design-notes.md read
   below. This is the backward-compatible path.

#### Standard .claude/design-notes.md Read

If .claude/design-notes.md exists (and was not loaded from the session file above), read
it and internalize:
- Project Vision and User Archetypes
- Golden Paths (critical workflows)
- UI Building Blocks (design system, navigation, key components)
- Interaction Rules (error handling, destructive actions, data density)

If .claude/design-notes.md does NOT exist (and the session file doesn't have it either),
inform the user that design context is missing and recommend running design
onboarding first. Use AskUserQuestion to ask whether to proceed without it or
stop.

### Step 4: Load UI Discovery Cache (or inventory components) (/dso:design-wireframe)

Attempt to load the UI Discovery Cache to avoid redundant Playwright crawls and
component scans. The cache is generated by the `/dso:ui-discover` skill.

1. Check for `.ui-discovery-cache/manifest.json`.

2. **If cache exists:**
   a. Check for `.ui-discovery-cache/validate-ui-cache.sh`. If missing, treat as corrupt
      cache and skip to step 3.
   b. Run: `bash .ui-discovery-cache/validate-ui-cache.sh`
   c. Parse the single-line JSON output:
      - `{"status":"valid"}` → proceed to sub-step 4 (load from cache).
      - `{"status":"stale",...}` → Use AskUserQuestion to ask the user:
        - "Refresh cache now" (run `/dso:ui-discover --refresh`, then reload)
        - "Proceed with stale data" (load from cache as-is)
        - "Stop" (halt the design process)
      - `{"status":"error",...}` → Use AskUserQuestion to ask:
        - "Generate cache now" (run `/dso:ui-discover`, then reload)
        - "Stop" (halt the design process)

3. **If no cache exists:** Use AskUserQuestion to ask the user:
   - "Generate cache now" (run `/dso:ui-discover`, then reload)
   - "Proceed without cache" (fall back to legacy component inventory below)
   - "Stop" (halt the design process)

4. **Load from cache:**
   a. Read `global/app-shell.json` — navigation structure, layout pattern,
      shared chrome. This replaces the need for app shell discovery.
   b. Read `global/design-tokens.json` — resolved theme tokens (colors→hex,
      spacing, typography, shadows, radii). These are used directly in Phase 4
      for token overlay generation.
   c. Read `global/route-map.json` — route-to-component mapping. Use this to
      identify which routes the story affects.
   d. Read `components/_index.json` — component inventory (replaces the legacy
      Glob+Grep inventory). This provides: component name, path, variants,
      and purpose for every component in the project.
   e. Identify affected routes: match the story description and acceptance
      criteria against route paths and component names in the route map.
   f. Read `routes/<slug>.json` for each affected route — these denormalized
      snapshots contain the full page context: layout, DOM structure, inline
      component details, patterns, and screenshot path.
   g. Read `screenshots/<slug>.png` for affected routes using the Read tool
      (images are viewable). Analyze existing layout, spacing, and component
      placement.
   h. Load individual `components/<Name>.json` on demand when making deep
      reuse decisions — these contain full prop types, defaults, related
      components, source excerpts, and design system refs.

   Note: Cache-loaded inventory includes richer data than the legacy approach:
   observed prop values from Playwright, usage frequency across routes, and
   related component relationships.

   Set an internal flag: `cacheLoaded = true`. Proceed to Phase 2.

5. **Legacy fallback** (if user chose "Proceed without cache"):

   Catalog the project's UI components to enable the Component Reuse principle.
   Use the resolved stack adapter (from **Stack Adapter Resolution** above) to
   determine discovery patterns.

   a. Use Glob to discover component files using the adapter's
      `component_file_patterns.glob_patterns` array. If no adapter was resolved,
      fall back to broad generic patterns: `**/*.html`, `**/*.tsx`, `**/*.jsx`,
      `**/*.vue`, `**/*.svelte`.

      Exclude files matching the adapter's `component_file_patterns.exclude_patterns`
      (e.g., `**/node_modules/**`, `**/.venv/**`). If no adapter, apply sensible
      defaults: `**/node_modules/**`, `**/.venv/**`, `**/dist/**`, `**/build/**`.

   b. Use Grep with the adapter's `component_file_patterns.definition_patterns`
      to find component/macro definitions and extract names and parameter lists.
      Use the adapter's `component_file_patterns.import_patterns` to find
      component imports and usage references.

      If no adapter was resolved, use heuristic grep for exported/defined
      component names and their prop interfaces.

   c. Build an inventory noting: component name, file path, available
      variants/props, and approximate purpose.

   Set an internal flag: `cacheLoaded = false`. Proceed to Phase 2.

---

## Phase 2: Application Review (/dso:design-wireframe)

This phase is conditional based on whether the UI Discovery Cache was loaded.

### If cache was loaded (`cacheLoaded = true`):

Phase 2 becomes a **verification step** — no Playwright crawl is needed.

**Step 5: Verify route coverage**

1. Confirm that the affected routes identified in Step 4e cover all pages the
   story touches. Cross-reference the story's description and acceptance
   criteria against the loaded route snapshots.

2. If the story introduces a **new page** (not present in the cache):
   - This page must be designed from scratch using the component inventory
     (`components/_index.json`) and app shell (`global/app-shell.json`).
   - Load additional route snapshots from similar pages for pattern reference.
   - Note that no screenshot or DOM structure is available for the new page.

3. Load additional `routes/<slug>.json` on demand for pattern reference if the
   story references functionality on pages not initially identified.

4. Proceed to Phase 3.

### If cache was NOT loaded (`cacheLoaded = false` — legacy fallback):

Execute the original Playwright-based application review:

**Step 5: Determine target pages**

Based on the story context, identify which application pages are relevant:
- Pages the story directly modifies or extends
- Pages with related functionality (for pattern reference)
- Navigation flows the user would traverse

**Step 6: Locate the running application**

Run the local environment preflight check:
```
.claude/scripts/dso check-local-env.sh
```

- **If exits 0**: The app is running. Use the `APP_PORT` (default 3000) for
  Playwright navigation.
- **If exits non-zero**: Use AskUserQuestion to ask the user:
  - "Fix environment and retry" (user fixes, then re-run the check)
  - "Skip live review" (proceed with source code analysis only)
  - "Stop" (halt the design process)

**Step 7: Capture current application state**

**If Playwright is available AND the app is running:**

Write a temporary Playwright script to `/tmp/design-capture-$ARGUMENTS.mjs` that:
- Launches chromium in headless mode
- Navigates to each target page identified in Step 5
- Waits for network idle
- Takes a full-page screenshot of each page
- Extracts a DOM summary: element tags, class names, IDs, ARIA attributes,
  and data attributes (limit to the top 3 levels of nesting)
- Saves screenshots to the design output directory (created in Phase 4)
- Outputs a JSON summary of findings to stdout

Run the script: `node /tmp/design-capture-$ARGUMENTS.mjs`

Read the screenshots with the Read tool (images are viewable). Analyze:
- Current layout patterns (grid, flexbox, sidebar, top-nav, etc.)
- Existing component usage (recurring class names, component patterns)
- Navigation structure
- Spacing and alignment conventions

**If Playwright is NOT available or the app is NOT running:**
- Log a warning that live application review was skipped
- Rely entirely on source code analysis from Step 4
- Note this limitation in the final design manifest

---

## Phase 3: Design Analysis (/dso:design-wireframe)

### Step 8: Apply Interaction Heuristics (/dso:design-wireframe)

For each interaction the story introduces, evaluate three HCD dimensions:

| Heuristic | Question | Design Implication |
|-----------|----------|-------------------|
| **Consequence** | Is this action reversible? | High consequence = add confirmation friction. Low = optimize for speed. |
| **Frequency** | How often will users do this? | High frequency = maximize efficiency and density. Low = add guidance and onboarding cues. |
| **Cognitive Load** | Must the user carry context from elsewhere? | High load = persistent sidebars, contextual hints, breadcrumbs. Low = clean, focused layout. |

Document the evaluation for each key interaction. This analysis goes into the
design manifest's rationale section.

### Step 9: Map components to the design (/dso:design-wireframe)

For each UI element in the proposed design, search the component inventory
from Step 4 for an existing match. Tag every element:

- `{EXISTING: ComponentName}` — use as-is from the design system
- `[MODIFIED: ComponentName]` — existing component needs new props or variants
- `[NEW: ProposedName]` — no existing component supports this need

**For [MODIFIED] components**: Describe the specific prop or variant changes
needed. This is preferable to creating a new component.

**For [NEW] components**: Provide a justification explaining why no existing
component can fulfill the requirement. Include:
- The proposed component name and purpose
- Its props/API surface
- How it relates to existing components (is it a composition? an extension?)

**Epic coherence check** (if a parent epic was found in Step 1):
- Before tagging any element as [NEW], check whether a sibling story's design
  already introduced a component that serves the same purpose. If so, tag it
  as {EXISTING} and reference the sibling's design manifest.
- Ensure layout patterns (navigation, page structure, section ordering) are
  consistent with sibling designs. If this story introduces a page that lives
  alongside pages designed in sibling stories, the navigation and information
  architecture must align.
- If this story's design must deviate from a sibling's established pattern,
  document the deviation and its rationale explicitly.

### Step 10: Apply the Pragmatic Scope Splitter (/dso:design-wireframe)

Compare the **Ideal UX** (best possible version) against the **Foundation UX**
(simplest version using only existing components).

**Decision rule**: If the Ideal UX requires creating 2 or more new components OR
complex custom state management, split the story:

- **Story A (Foundation)**: Meets the functional goal with existing components
  only. This is what the design manifest covers.
- **Story B (Enhancement)**: Adds the Ideal UX polish and custom components.
  Create this as a new ticket story linked to the original.

If a split is not needed, proceed with the Ideal UX as the single design.

---

## Phase 4: Design Creation (/dso:design-wireframe)

### Step 11: Generate design UUID and directory (/dso:design-wireframe)

Run: `python3 -c "import uuid; print(uuid.uuid4())"`

Resolve the design root so artifacts always land in the worktree, regardless of working directory:
```bash
DESIGN_ROOT=$(git rev-parse --show-toplevel)/designs
mkdir -p "$DESIGN_ROOT/<uuid>/screenshots"
```

All subsequent paths of the form `designs/<uuid>/...` mean `$DESIGN_ROOT/<uuid>/...` (absolute path).

**Initialize checkpoint**: Write `$DESIGN_ROOT/<uuid>/progress.json` with the context
accumulated from Phases 1-3. This enables recovery if the agent restarts:
```json
{
  "designId": "<uuid>",
  "storyId": "$ARGUMENTS",
  "epicId": "<epic ID or null>",
  "status": "in_progress",
  "currentPhase": 4,
  "startedAt": "<ISO timestamp>",
  "context": {
    "storyTitle": "<title>",
    "hasDesignNotes": true/false,
    "hasEpicContext": true/false,
    "siblingDesignCount": N,
    "componentInventorySize": N,
    "playwrightUsed": true/false,
    "scopeSplit": true/false
  },
  "artifacts": {}
}
```

After each subsequent step in Phase 4, update `progress.json` to record the
artifact path in the `artifacts` object (e.g., `"spatialLayout": "spatial-layout.json"`).
This ensures that if the agent restarts, completed artifacts are not regenerated.

### Step 12: Generate the Spatial Layout Tree (JSON) (/dso:design-wireframe)

Read [docs/output-format-reference.md](docs/output-format-reference.md) for the
complete JSON schema.

Create `designs/<uuid>/spatial-layout.json` containing the hierarchical DOM
structure with:
- Component references using the tags from Step 9
- `design_system_ref` paths for existing components
- `spatial_hint` for positioning (alignment, margins, flex properties)
- `props` for component configuration
- `aria` attributes for accessibility
- `responsive` breakpoint overrides
- `children` arrays reflecting nesting

Every component `id` in this file must be unique and will be referenced by the
SVG wireframe and token overlay.

### Step 13: Generate the Functional Blueprint (SVG) (/dso:design-wireframe)

Read [docs/output-format-reference.md](docs/output-format-reference.md) for SVG
conventions.

Create `designs/<uuid>/wireframe.svg` as a semantic SVG that:
- Uses a 1440x900 canvas for desktop layout
- Assigns element IDs matching the Spatial Layout Tree `id` fields
- Groups elements with `<g>` reflecting component hierarchy
- Uses `data-component` and `data-tag` attributes for machine readability
- Labels all interactive elements with descriptive text (never "Lorem ipsum")
- Includes annotation callouts for [NEW] and [MODIFIED] components
- Uses the standard color palette defined in the output format reference

The SVG must be optimized for LLM consumption: prioritize clear labeling,
semantic structure, and accurate spatial relationships over visual polish.

### Step 14: Generate the Design Token Overlay (Markdown) (/dso:design-wireframe)

Read [docs/output-format-reference.md](docs/output-format-reference.md) for the
token overlay format.

Create `designs/<uuid>/tokens.md` containing:
- **Interaction behaviors**: hover, focus, active, disabled states with tokens
- **Responsive rules**: breakpoint-specific layout changes
- **Accessibility specification**: ARIA roles, keyboard nav, screen reader text
- **State definitions**: loading, empty, error, success with visual descriptions
- **Design system tokens**: spacing, colors, typography, shadows, radii

**Color token resolution**: All color tokens MUST include their resolved hex
values in the format `token-name (#HEXVAL)`. Resolve values by reading the
project's theme configuration (e.g., `tailwind.config.js`, `theme.ts`, CSS
custom properties, or DESIGN_NOTES). Include a **Contrast Ratios** subsection
that pre-computes the WCAG contrast ratio for every foreground/background color
pairing used in the design. This enables the Accessibility Specialist reviewer
to verify WCAG 1.4.3 (Contrast Minimum) and 1.4.11 (Non-text Contrast) without
needing access to the source code.

### Checkpoint: Validate artifact consistency

Before assembling the manifest, verify that element IDs are consistent across
all three design artifacts. This is the critical integrity check for the
ID-Linkage Method that the implementation agent depends on.

1. Read `designs/<uuid>/spatial-layout.json` and collect every component `id`
   value, including those nested inside `children` arrays at all depths.
   Call this set **JSON_IDS**.

2. Read `designs/<uuid>/wireframe.svg` and collect every `id` attribute on
   elements (excluding the SVG root and `<defs>`). Call this set **SVG_IDS**.

3. Read `designs/<uuid>/tokens.md` and collect every Element ID referenced in
   the first column of the Interaction Behaviors, Responsive Rules, Accessibility
   Specification, and State Definitions tables. Call this set **TOKEN_IDS**.

4. Compare the three sets:

   | Discrepancy | Meaning | Action |
   |-------------|---------|--------|
   | ID in JSON_IDS but not SVG_IDS | Component has no wireframe representation | Add the element to the SVG, or remove it from JSON if it's a non-visual component (document why) |
   | ID in JSON_IDS but not TOKEN_IDS | Component has no behavioral specification | Add entries to tokens.md for this element's interactions, states, and a11y |
   | ID in SVG_IDS but not JSON_IDS | Orphaned SVG element with no component mapping | Remove from SVG, or add to JSON if it was accidentally omitted |
   | ID in TOKEN_IDS but not JSON_IDS | Token references a non-existent component | Fix the reference in tokens.md |

5. Fix all discrepancies by editing the relevant artifact(s). Re-run this
   check until all three sets are identical (excluding intentionally non-visual
   components, which must be documented with a `"visual": false` flag in the
   JSON node).

6. Update `progress.json`: set `"artifacts"` to include all three files and
   add `"idValidation": "passed"`.

### Step 15: Assemble the Design Manifest (/dso:design-wireframe)

Read [templates/design-manifest-template.md](templates/design-manifest-template.md)
for the template.

Create `designs/<uuid>/manifest.md` combining:
- Story reference (ID, title, description, acceptance criteria)
- **Epic context** (if applicable): parent epic ID and vision, sibling story
  design references, how this story fits into the epic's unified UX, and any
  cross-story dependencies or shared components
- Design rationale (heuristic evaluation from Step 8)
- Component mapping table with reuse ratio (Step 9)
- Scope assessment (Step 10)
- Links to all three artifacts
- Implementation strategy using the ID-Linkage Method
- State change table (default, loading, success, error, empty)
- Accessibility assertions
- UX friction review

---

## Phase 5: Design Review (/dso:design-wireframe)

This phase uses `REVIEW-PROTOCOL-WORKFLOW.md` at Stage 2 (skipping Stage 1 because Phase 4's
artifact consistency checkpoint already serves as the mental pre-review).

> **NESTING PROHIBITION**: Do NOT invoke `/dso:review-protocol` via the Skill tool here.
> This skill may already be at nesting level 2+ (e.g., `sprint → preplanning → design-wireframe`).
> A Skill tool call to `/dso:review-protocol` would create 3+ levels, which fails to return control.
> Always read and execute the workflow inline.

### Step 16: Submit for committee review (/dso:design-wireframe)

Read [docs/review-criteria.md](docs/review-criteria.md) for reviewer prompt
files and domain-specific review context.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md` inline with:

- **subject**: "Design Wireframe: {story title}"
- **artifact**: The design artifacts (manifest, spatial layout JSON, SVG wireframe description, design tokens) plus story context and epic context (if applicable)
- **pass_threshold**: 4
- **start_stage**: 2 (Phase 4 artifact validation serves as Stage 1)
- **max_revision_cycles**: 3
- **perspectives**: Defined by the four reviewer prompt files. For each reviewer, read its prompt file and map to the `REVIEW-PROTOCOL-WORKFLOW.md` perspective format:

**Reviewer 1 — Product Management** (from [docs/reviewers/product-manager.md](docs/reviewers/product-manager.md)):
- Dimensions: `story_alignment`, `user_value`, `scope_appropriateness`, `consistency`, `epic_coherence`
- Context: Story context, epic context (if applicable), manifest, JSON, SVG description, tokens
- Additional: `anti_pattern_compliance` (from `/dso:design-review` North Star Check — validates against DESIGN_NOTES anti-patterns)

**Reviewer 2 — Design Systems** (from [docs/reviewers/design-systems-lead.md](docs/reviewers/design-systems-lead.md)):
- Dimensions: `component_reuse`, `visual_hierarchy`, `design_system_compliance`, `new_component_justification`, `cross_story_consistency`
- Context: Above plus component inventory from Step 4 and UI Building Blocks from DESIGN_NOTES

**Reviewer 3 — Accessibility** (from [docs/reviewers/accessibility-specialist.md](docs/reviewers/accessibility-specialist.md)):
- Dimensions: `wcag_compliance`, `keyboard_navigation`, `screen_reader_support`, `inclusive_design`
- Context: Above. Domain-specific field: `wcag_criterion` in findings
- Additional: `hcd_heuristics` (from `/dso:design-review` Usability Check — visibility of status, error prevention)

**Reviewer 4 — Frontend Engineering** (from [docs/reviewers/frontend-engineer.md](docs/reviewers/frontend-engineer.md)):
- Dimensions: `implementation_feasibility`, `performance`, `state_complexity`, `specification_clarity`
- Context: Above plus tech stack from DESIGN_NOTES and source of MODIFIED components. Domain-specific field: `complexity_estimate` in findings

Because design reviews genuinely benefit from diverse perspectives, **always use
multi-agent dispatch** (one sub-agent per reviewer, launched in parallel via the
Task tool). This bypasses `REVIEW-PROTOCOL-WORKFLOW.md`'s default single-agent approach.

Since subagents cannot view images, describe the SVG wireframe's structure and
spatial relationships in text when constructing each prompt.

Each reviewer returns JSON conforming to `REVIEW-SCHEMA.md` format: `perspective`,
`status`, `dimensions` map, and `findings` array with `severity`, `description`,
and `suggestion`.

### Step 17: Evaluate review results (/dso:design-wireframe)

Aggregate the four reviewer JSON outputs into a single `REVIEW-SCHEMA.md`-compliant
object with all four entries in the `reviews` array.

The design **passes** if ALL dimension scores across ALL reviewers are 4, 5, or null.

**Conflict detection**: Scan all findings for direct contradictions — pairs of
suggestions that target the same component/artifact but pull in opposite directions
(add vs remove, more vs less, strict vs flexible, expand vs reduce). Populate the
`conflicts` array. Resolution follows `REVIEW-PROTOCOL-WORKFLOW.md`:
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user via AskUserQuestion
- Both minor: caller chooses

Log the full review to `designs/<uuid>/review-log.md`.

Update `progress.json`: set `"currentPhase": 5`, add `"reviewCycle": N`, and
record the aggregate pass/fail result.

- If all scores pass and no unresolved conflicts: proceed to Phase 6.
- If any score is below 4 (and no conflicts require escalation): proceed to Step 18.

### Step 18: Revise and re-submit (max 3 cycles) (/dso:design-wireframe)

Follow `REVIEW-PROTOCOL-WORKFLOW.md`'s revision protocol:

1. **Triage by severity**: Address critical findings first, then major, then minor.
2. **Resolve conflicts first**: If `conflicts[]` is non-empty, resolve before revising.
3. **Revise**: For each finding, modify the relevant artifact(s) — JSON, SVG, tokens, or manifest. Document the change in `designs/<uuid>/review-log.md` with before/after description.
4. **Re-submit**: Return to Step 16 with full revised artifacts (not just changes).

**After the 3rd failed review cycle:**
- Do NOT revise automatically
- Present the user with:
  - The current design state and artifact locations
  - All unresolved feedback across all review cycles
  - Specific questions about which direction to take
- Use AskUserQuestion to gather the user's design guidance
- Apply the user's input, then submit one final review

---

## Phase 6: Finalization (/dso:design-wireframe)

### Step 19: Update the ticket story (/dso:design-wireframe)

Link the approved design artifacts to the story:

```
.claude/scripts/dso ticket comment $ARGUMENTS "Design Manifest: designs/<uuid>/manifest.md | Spatial Layout: designs/<uuid>/spatial-layout.json | Wireframe: designs/<uuid>/wireframe.svg | Tokens: designs/<uuid>/tokens.md | Review: designs/<uuid>/review-log.md"
```

If the story was split in Step 10, also create the enhancement story:
```
.claude/scripts/dso ticket create story "Enhancement: <title>" -p <same priority> -d "<description referencing foundation story $ARGUMENTS>"
.claude/scripts/dso ticket link <new-story-id> $ARGUMENTS depends_on
```

Update `progress.json`: set `"status": "complete"` and `"currentPhase": 6`.

### Step 20: Report completion (/dso:design-wireframe)

Summarize for the user:
- Story ID and title
- Design UUID and artifact file paths
- Review outcome (passed on cycle N, or user-guided after cycle 3)
- Component reuse ratio (% existing / % modified / % new)
- Key design decisions and rationale
- Any split stories created with their IDs
- Next step: the implementation agent can consume the Design Manifest using
  the ID-Linkage Method documented in the manifest

---

## Error Handling

| Condition | Action |
|-----------|--------|
| `ticket` CLI not installed | Stop. Tell user to install ticket CLI. |
| Story ID not found | Stop. Report invalid story ID. |
| .claude/design-notes.md missing | Warn. Ask user whether to proceed or run onboarding. |
| Playwright unavailable | Warn. Skip live review; rely on source analysis. Note in manifest. |
| App not running | Warn. Skip screenshots. Note in manifest. |
| No components found | Warn. All elements will be tagged [NEW]. Note high new-component ratio. |
| Cache stale, user declines refresh | Proceed with stale data. Note in manifest. |
| Cache missing, user declines generation | Fall back to legacy Steps 4-5 + 5-7. |
| Cache validation script missing | Treat as corrupt cache. Recommend `/dso:ui-discover`. |
| Route not in cache (new page) | Design from scratch using component inventory + app shell. |
| UUID generation fails | Fall back to: `cat /proc/sys/kernel/random/uuid` or timestamp-based ID. |
| Review cycle 3 failure | Escalate to user via AskUserQuestion. Never loop beyond 3 automated cycles. |
