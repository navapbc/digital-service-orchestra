# Design Output Format Reference

## The Triad Source of Truth

Every design consists of three complementary artifacts that together form an
unambiguous specification for an implementation agent. No single format captures
everything an LLM needs: the JSON provides structure, the SVG provides spatial
relationships, and the Markdown provides behavior and constraints.

---

## 1. Spatial Layout Tree (JSON)

The Spatial Layout Tree defines the hierarchical structure of the UI. It maps
directly to the intended DOM structure and explicitly references design system
components. The implementation agent reads this first to build the component tree.

### JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["storyId", "designId", "layout", "components"],
  "properties": {
    "storyId": {
      "type": "string",
      "description": "The ticket story ID this design addresses"
    },
    "designId": {
      "type": "string",
      "format": "uuid",
      "description": "UUID of this design"
    },
    "layout": {
      "type": "string",
      "description": "Top-level layout pattern, e.g. 'StickyHeader-Main-Footer', 'Sidebar-Content', 'TopNav-Sidebar-Main'"
    },
    "breakpoints": {
      "type": "object",
      "description": "Responsive breakpoint definitions used in responsive overrides",
      "properties": {
        "sm": { "type": "string", "default": "640px" },
        "md": { "type": "string", "default": "768px" },
        "lg": { "type": "string", "default": "1024px" },
        "xl": { "type": "string", "default": "1280px" }
      }
    },
    "components": {
      "type": "array",
      "description": "Top-level component nodes; nesting is expressed via children",
      "items": { "$ref": "#/definitions/component" }
    }
  },
  "definitions": {
    "component": {
      "type": "object",
      "required": ["id", "type", "tag"],
      "properties": {
        "id": {
          "type": "string",
          "description": "Unique identifier. MUST match the corresponding SVG element ID and token overlay element references."
        },
        "type": {
          "type": "string",
          "description": "Component type name, e.g. 'Button', 'SearchInput', 'DataTable'"
        },
        "tag": {
          "type": "string",
          "enum": ["EXISTING", "MODIFIED", "NEW"],
          "description": "EXISTING = use as-is. MODIFIED = needs prop/variant changes. NEW = must be created."
        },
        "design_system_ref": {
          "type": "string",
          "description": "Path in the design system, e.g. 'Components/Forms/SearchInput'. Omit for NEW components."
        },
        "spatial_hint": {
          "type": "string",
          "description": "Positioning guidance: 'Top-right, 24px margin', 'Flex-grow, centered', 'Grid col 2-4, row 1'"
        },
        "props": {
          "type": "object",
          "description": "Component props/configuration to pass"
        },
        "modification_notes": {
          "type": "string",
          "description": "For MODIFIED components only: what changes are needed and why"
        },
        "justification": {
          "type": "string",
          "description": "For NEW components only: why no existing component works"
        },
        "responsive": {
          "type": "object",
          "description": "Breakpoint-specific property overrides. Keys are breakpoint names from the breakpoints object.",
          "additionalProperties": {
            "type": "object",
            "description": "Overrides to spatial_hint, props, or visibility at this breakpoint"
          }
        },
        "aria": {
          "type": "object",
          "description": "Accessibility attributes. Every interactive element MUST have at minimum a role and label.",
          "properties": {
            "role": { "type": "string" },
            "label": { "type": "string" },
            "describedby": { "type": "string" },
            "live": { "type": "string", "enum": ["polite", "assertive", "off"] },
            "expanded": { "type": "boolean" },
            "controls": { "type": "string" },
            "haspopup": { "type": "string" }
          }
        },
        "children": {
          "type": "array",
          "description": "Nested child components",
          "items": { "$ref": "#/definitions/component" }
        }
      }
    }
  }
}
```

### Example

```json
{
  "storyId": "w21-a1b2",
  "designId": "550e8400-e29b-41d4-a716-446655440000",
  "layout": "TopNav-Sidebar-Main",
  "breakpoints": { "sm": "640px", "md": "768px", "lg": "1024px" },
  "components": [
    {
      "id": "search-section",
      "type": "Section",
      "tag": "EXISTING",
      "design_system_ref": "Layout/Section",
      "spatial_hint": "Full-width, 24px vertical padding",
      "children": [
        {
          "id": "search-input",
          "type": "SearchInput",
          "tag": "EXISTING",
          "design_system_ref": "Components/Forms/SearchInput",
          "spatial_hint": "Max-width 600px, horizontally centered",
          "props": { "variant": "ghost", "icon": "search", "placeholder": "Search items..." },
          "aria": { "role": "search", "label": "Search items" }
        },
        {
          "id": "filter-bar",
          "type": "FilterChipGroup",
          "tag": "NEW",
          "justification": "No existing component supports multi-select filter chips with active state toggle. ChipGroup exists but lacks filter semantics and active state styling.",
          "spatial_hint": "Below search, left-aligned, 12px gap between chips",
          "props": { "chips": ["Status", "Priority", "Assignee"], "multiSelect": true },
          "responsive": {
            "sm": { "spatial_hint": "Horizontal scroll, single row, hide overflow" }
          },
          "aria": { "role": "toolbar", "label": "Filter options" }
        }
      ]
    }
  ]
}
```

### Rules

- Every `id` must be unique across the entire tree.
- Every `id` must have a corresponding element in the SVG wireframe.
- Every interactive element must have an `aria` object with at least `role` and `label`.
- EXISTING components must have a `design_system_ref`.
- MODIFIED components must have `modification_notes`.
- NEW components must have `justification`.

---

## 2. Functional Blueprint (SVG)

The SVG wireframe is a spatial representation of the design. It shows exact
layout, proportions, and component arrangement. It is both visually renderable
(for human review) and machine-readable (via XML element IDs and data attributes).

### Canvas Standards

| Viewport | Width | Height | Use |
|----------|-------|--------|-----|
| Desktop (primary) | 1440px | 900px (or taller) | Default design target |
| Tablet (if needed) | 768px | 1024px | Responsive variant |
| Mobile (if needed) | 375px | 812px | Responsive variant |

Use `viewBox` for scalability: `viewBox="0 0 1440 900"`.

### Color Palette

These colors are for the wireframe only (not the final UI). They communicate
element type and status to both human and LLM reviewers.

| Color | Hex | Use |
|-------|-----|-----|
| Container BG | `#E8E8E8` | Section and container backgrounds |
| Component BG | `#FFFFFF` | Individual component backgrounds |
| Text / Labels | `#333333` | All text content and labels |
| Interactive | `#0066CC` | Buttons, links, clickable elements |
| Destructive | `#CC0000` | Delete, error, destructive actions |
| Success | `#00AA44` | Success states, confirmations |
| Disabled | `#999999` | Placeholder and disabled elements |
| Annotation | `#FFD700` | Callouts, notes, design annotations |
| NEW tag | `#FF6600` | Highlight for NEW components |
| MODIFIED tag | `#9933CC` | Highlight for MODIFIED components |

### Element Conventions

- **Element IDs**: MUST match the `id` field in the Spatial Layout Tree JSON.
- **Grouping**: Use `<g>` elements to reflect the component hierarchy from the
  JSON tree. Nest `<g>` elements matching parent-child relationships.
- **Data attributes**:
  - `data-component="ComponentName"` — the component type
  - `data-tag="EXISTING|MODIFIED|NEW"` — reuse classification
  - `data-interaction="hover|click|focus|drag"` — primary interaction type
- **Text content**: Use realistic, descriptive text. Never use "Lorem ipsum" or
  placeholder gibberish. Example: "Search items..." not "Lorem dolor".
- **Interactive indicators**: Add a small icon or badge to elements that have
  click, hover, or keyboard interactions.

### Annotation Conventions

Annotations explain non-obvious design decisions directly in the wireframe:

- Use `<text class="annotation">` with the annotation color (`#FFD700`)
- Connect annotations to their target with dashed lines:
  `<line stroke="#FFD700" stroke-dasharray="4" />`
- Annotate ALL [NEW] and [MODIFIED] components
- Annotate non-obvious interactions (e.g., "Drag to reorder", "Double-click to edit")

### Required SVG Structure

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1440 900">
  <defs>
    <style>
      .container { fill: #E8E8E8; stroke: #CCCCCC; stroke-width: 1; }
      .component { fill: #FFFFFF; stroke: #333333; stroke-width: 1; }
      .interactive { fill: #0066CC; }
      .text-label { font-family: system-ui, sans-serif; font-size: 14px; fill: #333333; }
      .text-heading { font-family: system-ui, sans-serif; font-size: 20px; font-weight: bold; fill: #333333; }
      .text-small { font-family: system-ui, sans-serif; font-size: 11px; fill: #666666; }
      .annotation { font-family: system-ui, sans-serif; font-size: 11px; fill: #666600; font-style: italic; }
      .tag-new { fill: none; stroke: #FF6600; stroke-width: 2; stroke-dasharray: 6 2; }
      .tag-modified { fill: none; stroke: #9933CC; stroke-width: 2; stroke-dasharray: 6 2; }
    </style>
  </defs>

  <!-- Title block -->
  <text class="text-heading" x="24" y="30">Wireframe: [Story Title]</text>
  <text class="text-small" x="24" y="48">Story: [ID] | Design: [UUID] | Viewport: Desktop 1440x900</text>
  <line x1="0" y1="56" x2="1440" y2="56" stroke="#CCCCCC" />

  <!-- Component groups go here, nested to match JSON hierarchy -->
  <!-- Annotations go in a final group layered on top -->

  <g id="annotations">
    <!-- Annotation callouts for NEW and MODIFIED components -->
  </g>
</svg>
```

---

## 3. Design Token Overlay (Markdown)

The token overlay captures everything invisible in the wireframe: behavior,
animation, responsive logic, accessibility specifics, and state management.
The implementation agent reads this after building the DOM structure from the
JSON and setting layout from the SVG.

### Required Sections

#### Interaction Behaviors

| Element ID | Trigger | Behavior | Design Token / CSS Value |
|------------|---------|----------|--------------------------|
| search-input | focus | Border highlight, expand width | `border-color: primary-500; transition: width 200ms ease` |
| filter-chip | click | Toggle active/inactive | `bg: neutral-100 → primary-100; color: neutral-700 → primary-700` |
| submit-btn | hover | Elevate shadow | `box-shadow: shadow-sm → shadow-lg; transition: 150ms ease` |
| delete-btn | click | Show confirmation dialog | N/A — triggers [EXISTING: ConfirmDialog] |

#### Responsive Rules

| Breakpoint | Element ID | Change Description |
|------------|-----------|-------------------|
| < md (768px) | sidebar | Collapse to hamburger menu. `display: none` on sidebar; show menu trigger button in header. |
| < sm (640px) | filter-bar | Horizontal scroll with overflow hidden. `overflow-x: auto; flex-wrap: nowrap` |
| < sm (640px) | search-input | Full width. Remove `max-width`; set `width: 100%` |
| < sm (640px) | data-table | Switch to card layout. Each row becomes a stacked card. |

#### Accessibility Specification

| Element ID | ARIA Pattern | Keyboard Interaction | Screen Reader Announcement |
|------------|-------------|---------------------|---------------------------|
| search-input | Search landmark | `Enter` submits, `Esc` clears | "Search items, edit text, type to search" |
| filter-bar | Toolbar | `Arrow keys` navigate chips, `Space` toggles | "Filter options toolbar, 3 items" |
| filter-chip | Toggle button | `Space` or `Enter` to toggle | "[Label] filter, pressed/not pressed" |
| results-list | Feed or list | `Arrow keys` navigate items, `Enter` opens | "[N] results. [Item title], [summary]" |
| delete-btn | Button | `Enter` or `Space` activates | "Delete [item name], button" |

Focus management notes:
- After search submission, move focus to the results count announcement
- After filter toggle, keep focus on the toggled chip
- After modal close, return focus to the triggering element
- Tab order follows visual layout: header → search → filters → content → footer

#### State Definitions

| State | Trigger | Visual Description | Duration |
|-------|---------|-------------------|----------|
| Default | Page load | All components visible, no data loaded yet | — |
| Loading | Search submitted / filter changed | Skeleton placeholders replace content area | Until API responds |
| Success | API returns results | Results populate content area with animation | `fade-in 200ms` |
| Empty | API returns 0 results | Illustration + "No results found" + suggestion text | — |
| Error | API failure (4xx/5xx) | Inline alert banner above results area, `role="alert"` | Until dismissed or retry succeeds |
| Partial error | Some data loaded, some failed | Loaded data visible + inline error for failed section | — |

#### Design System Tokens Applied

List every design token referenced by this design. **Color tokens MUST include
their resolved hex values** so that reviewers (especially the Accessibility
Specialist) can verify WCAG contrast ratios at design time. Resolve hex values
by reading the project's theme/token configuration files (e.g.,
`tailwind.config.js`, `theme.ts`, CSS custom properties, or DESIGN_NOTES).

```
Spacing:
  - space-2 (8px): chip internal padding
  - space-3 (12px): gap between filter chips
  - space-4 (16px): component internal padding
  - space-6 (24px): section padding

Typography:
  - text-heading-lg (24px/32px, 600): page title
  - text-body-lg (18px/28px, 400): search input text
  - text-label-sm (12px/16px, 500): filter chip labels
  - text-body-md (16px/24px, 400): result item content

Colors (token → hex → usage):
  - color-primary-500 (#0066CC): active filter state, focused input border
  - color-primary-100 (#E6F0FF): active filter chip background
  - color-neutral-100 (#F5F5F5): inactive filter chip background
  - color-neutral-200 (#E5E5E5): container borders
  - color-neutral-700 (#404040): body text
  - color-error-500 (#D32F2F): error alert border and icon
  - color-error-50 (#FFEBEE): error alert background
  - color-success-500 (#2E7D32): success state icon
  - color-surface (#FFFFFF): component backgrounds

Contrast Ratios (verify these meet WCAG 2.1 AA minimums):
  - color-neutral-700 on color-surface: #404040 on #FFFFFF = 9.7:1 (pass, AA requires 4.5:1)
  - color-primary-500 on color-surface: #0066CC on #FFFFFF = 5.3:1 (pass)
  - color-neutral-700 on color-neutral-100: #404040 on #F5F5F5 = 8.2:1 (pass)
  - color-error-500 on color-error-50: #D32F2F on #FFEBEE = 5.1:1 (pass)

Shadows:
  - shadow-sm: 0 1px 2px rgba(0,0,0,0.05) — card default state
  - shadow-lg: 0 4px 12px rgba(0,0,0,0.15) — card hover state, modal overlay

Border Radius:
  - radius-sm (4px): input fields, buttons
  - radius-md (8px): cards, containers
  - radius-full (9999px): chips, avatars

Transitions:
  - transition-fast: 150ms ease (hover effects)
  - transition-normal: 200ms ease (layout changes)
  - transition-slow: 300ms ease (modal enter/exit)
```

---

## Implementation Strategy: The ID-Linkage Method

The receiving implementation agent consumes the three artifacts in this order:

### Step 1: Structure (JSON → Component Tree) (dso:ui-designer)

Open `spatial-layout.json`. Build the component tree top-down:
- Each `component` node becomes a React/Vue/Svelte component instance
- `tag: "EXISTING"` → import from the design system using `design_system_ref`
- `tag: "MODIFIED"` → import and extend per `modification_notes`
- `tag: "NEW"` → create a new component per the specification
- Pass `props` as component properties
- Apply `aria` attributes directly to the DOM element

### Step 2: Layout (SVG → CSS) (dso:ui-designer)

**Priority rule**: When the JSON `spatial_hint` conflicts with SVG coordinates,
**`spatial_hint` takes precedence**. The SVG communicates approximate proportions
and relative positioning between elements; it is not a pixel-accurate
specification. Use the SVG to understand the overall spatial arrangement and
element grouping, then implement the precise layout using the `spatial_hint`
values and design tokens.

Open `wireframe.svg` as XML. For each element ID:
- Extract position (`x`, `y`) and dimensions (`width`, `height`) as
  **approximate layout guidance** — these indicate proportions, not exact CSS
- Compute relative positions to determine flex/grid properties
- Note `rx`/`ry` for border-radius
- Note grouping (`<g>`) for flex/grid container relationships
- Cross-reference with `spatial_hint` in the JSON for authoritative layout
  values (e.g., "Max-width 600px, centered" overrides an SVG `width="580"`)

### Step 3: Behavior (Tokens → Interaction Logic) (dso:ui-designer)

Open `tokens.md`:
- Implement each interaction behavior using the specified tokens
- Apply responsive rules at the specified breakpoints
- Implement all ARIA patterns and keyboard interactions
- Build state management for each defined state
- Map design token names to the project's actual token values

### Step 4: Verify (Cross-Reference) (dso:ui-designer)

For every element ID that appears in ANY artifact, verify it appears in ALL
three. A missing ID means something was specified but not fully defined.
Flag any discrepancies before implementation.
