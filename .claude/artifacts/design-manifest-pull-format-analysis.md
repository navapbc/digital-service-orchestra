# Design Manifest Pull Format Analysis

Comparative analysis of pull-back conversion approaches for the Figma designer collaboration workflow.

## The Core Problem

DSO's 3-artifact design manifest captures two fundamentally different types of information:

### Visual Specification (what the designer CAN revise in Figma)
- Component hierarchy and nesting
- Spatial arrangement (positions, sizes, proportions)
- Colors, typography, spacing values
- Which components exist and where they are placed
- Content (text labels, headings, placeholder text)

### Behavioral Specification (what the designer CANNOT revise in Figma)
- Interaction behaviors (hover, click, focus, drag handlers)
- State machine definitions (loading, error, empty, success states)
- Responsive breakpoint rules (what changes at each viewport size)
- Accessibility specification (ARIA roles, keyboard navigation, screen reader announcements, focus management)
- EXISTING/MODIFIED/NEW classification (design system sourcing strategy)
- `design_system_ref` paths (where to import components from)
- `modification_notes` and `justification` (designer intent behind component decisions)

**The pull-back is a merge problem, not a format conversion problem.** Visual changes from Figma must be reconciled with behavioral specifications preserved from the original manifest.

---

## Current 3-Artifact Format Reference

| Artifact | Format | Size (typical) | Captures | Token Cost to Read |
|----------|--------|----------------|----------|--------------------|
| spatial-layout.json | JSON | 3-8 KB | Component tree, props, ARIA, spatial hints, responsive overrides, tags | ~2-5k tokens |
| wireframe.svg | SVG/XML | 8-20 KB | Visual layout, proportions, annotations, data attributes | ~5-12k tokens |
| tokens.md | Markdown | 4-10 KB | Interactions, responsive rules, a11y spec, states, design tokens | ~3-7k tokens |
| **Total** | | **15-38 KB** | **Complete design specification** | **~10-24k tokens** |

The ID-Linkage Method ensures every element appears in all 3 artifacts with the same ID, enabling cross-referencing.

---

## What Figma MCP Returns on Pull-Back

| MCP Tool | Returns | Maps To |
|----------|---------|---------|
| `get_design_context` | Structured design data + generated code (React+Tailwind default) | Component hierarchy, props, styles → partial spatial-layout.json |
| `get_metadata` | Sparse XML: layer IDs, names, types, positions, sizes | Element positions → partial wireframe.svg spatial data |
| `get_variable_defs` | Variables and styles (colors, spacing, typography tokens) | Design token values → partial tokens.md (Section 5 only) |
| `get_screenshot` | PNG image of selection | Visual reference (requires multi-modal interpretation — NOT desired) |

### What's RECOVERABLE from Figma pull-back:
- Component hierarchy (names, nesting)
- Spatial positions and sizes
- Colors, typography, spacing values
- Text content
- Frame/component names (if designer preserved them)

### What's NOT RECOVERABLE from Figma pull-back:
- EXISTING/MODIFIED/NEW tags
- `design_system_ref` paths
- `modification_notes` and `justification`
- Interaction behaviors (hover, click, focus handlers)
- State machine definitions
- Responsive breakpoint rules
- Accessibility specification (ARIA roles, keyboard nav, screen reader text)
- Focus management strategy
- Transition/animation specifications

---

## Comparative Analysis: 3 Proposed Approaches vs Current Format

### Option 1: Design Change Spec (Structured Diff in Markdown)

**What it produces:** A markdown document describing what the designer changed.

**Design intent preservation:** LOW-MEDIUM
- Captures WHAT changed but not the full updated specification
- Implementation agent must mentally reconstruct the final state by applying the diff to the original manifest
- If the designer added a new component, the diff says "added a filter dropdown" but doesn't provide the full component spec (props, ARIA, spatial hints, responsive rules)
- Loses ID-linkage integrity — new elements from the designer don't have IDs in the original artifacts
- The "merge" happens in the implementation agent's head, not in the artifacts

**Token efficiency:** BEST (~2-4k tokens)
- Smallest output — only describes the delta
- But the implementation agent must ALSO read the original 3 artifacts to understand the full state
- Effective cost: 2-4k (diff) + 10-24k (original artifacts) = ~12-28k total

**Failure modes:**
- Ambiguous descriptions: "moved the chart to the left" — how far left? what's the new spatial relationship?
- Missing implications: designer moved a component, but the diff doesn't mention that responsive rules need updating
- Lossy translation: converting Figma's visual changes to natural language loses precision

**Verdict:** Optimizes for the wrong thing. Saves tokens on the diff artifact but forces the implementation agent to do imprecise mental reconstruction. Design intent degrades at the merge step.

---

### Option 2: Updated spatial-layout.json

**What it produces:** A regenerated spatial-layout.json reflecting the designer's revisions, with the other 2 artifacts updated to match.

**Design intent preservation:** HIGHEST
- The implementation agent consumes the SAME format it already knows (ID-Linkage Method, 3-step consumption pattern)
- No new artifact type — no learning curve or format ambiguity
- Behavioral specifications from the original manifest are preserved and merged with visual changes
- ID-linkage integrity is maintained — new elements get proper IDs, removed elements are cleaned up across all 3 artifacts
- The "merge" happens at artifact generation time, not in the implementation agent's head

**Token efficiency:** MEDIUM (~10-24k tokens for full 3-artifact set)
- Same cost as the original design manifest
- But the implementation agent doesn't need to read TWO artifacts (diff + original) — just the updated one
- If we include a changelog section in the updated manifest, the agent can prioritize what changed

**The conversion challenge:**
This is the hardest approach to BUILD because it requires:
1. Pull Figma design context → extract component hierarchy
2. Diff against original spatial-layout.json → identify what changed
3. For NEW components (ones the designer added): generate full specs (props, ARIA, spatial hints)
4. For REMOVED components: clean up across all 3 artifacts
5. For MODIFIED components: merge visual changes with preserved behavioral specs
6. Regenerate wireframe.svg from updated positions
7. Update tokens.md with new/changed design token values while preserving interaction/a11y/state specs

Steps 3 and 5 are where design intent is at risk. The conversion agent must infer behavioral specs for designer-added components and reconcile visual changes with existing behavioral specs.

**Mitigation for the conversion challenge:**
- The conversion agent has ACCESS to the original 3 artifacts (full behavioral context)
- For designer-added components: generate PLACEHOLDER behavioral specs tagged as `[NEEDS_REVIEW]` so the implementation agent knows to verify
- For visual changes to existing components: update spatial-layout.json positions/sizes, preserve behavioral specs unless the visual change implies a behavioral change (e.g., component was repositioned into a different section → responsive rules may need updating)

**Verdict:** Highest fidelity, hardest to build. But the complexity is in the CONVERSION step (a one-time engineering problem), not in the CONSUMPTION step (which happens every time an implementation agent reads the design).

---

### Option 3: Revised Wireframe HTML + Diff Summary

**What it produces:** The revised HTML wireframe from Figma + a markdown summary of what changed.

**Design intent preservation:** LOW
- The HTML wireframe captures VISUAL layout only — it was designed as a human-reviewable artifact, not an implementation spec
- Missing entirely: component hierarchy semantics (EXISTING/MODIFIED/NEW), design system refs, interaction specs, state machines, a11y spec, responsive rules
- The implementation agent would need to reverse-engineer component structure from HTML — the exact problem the 3-artifact format was designed to avoid
- The diff summary adds natural-language context but shares all the ambiguity problems of Option 1
- Creates a FORMAT DIVERGENCE: the canonical design format is 3 artifacts, but the Figma round-trip produces HTML + markdown — two incompatible representations of the same design

**Token efficiency:** MEDIUM-HIGH (~5-10k for HTML + ~2k for summary = ~7-12k)
- Cheaper than full 3-artifact regeneration
- But the implementation agent gets LESS information per token — lower information density
- If the agent needs behavioral specs, it must also read the original tokens.md → effective cost rises

**Failure modes:**
- Implementation agent treats HTML as authoritative code → implements the wireframe literally instead of understanding the design intent
- HTML structure doesn't match the project's component library → agent creates wrong components
- No ID-linkage → no way to cross-reference with behavioral specs in original tokens.md

**Verdict:** Cheapest to produce, lowest fidelity. The HTML wireframe was a useful PUSH artifact (gets designs into Figma for human review) but is a poor PULL artifact (doesn't carry enough structured information for implementation).

---

## Recommendation: Option 2 with Layered Architecture

### The approach: Regenerate the full 3-artifact design manifest from the Figma pull-back

**Architecture:**

```
Original 3-artifact manifest (pre-Figma)
    + Figma designer revisions (via MCP read tools)
    → Conversion agent merges visual changes with behavioral specs
    → Updated 3-artifact manifest (post-Figma)
    + Changelog section documenting what the designer changed
```

### The conversion agent's merge algorithm:

**Step 1: Pull visual state from Figma**
- `get_design_context` → component hierarchy + generated code
- `get_metadata` → element positions, sizes, names
- `get_variable_defs` → design token values

**Step 2: Diff against original spatial-layout.json**
- Identify ADDED components (in Figma but not in original JSON)
- Identify REMOVED components (in original JSON but not in Figma)
- Identify MOVED/RESIZED components (same ID, different position/size)
- Identify RESTYLED components (same position, different visual properties)

**Step 3: Merge with behavioral preservation**

| Change Type | Visual Update | Behavioral Handling |
|-------------|---------------|-------------------|
| Component MOVED | Update `spatial_hint` in JSON | Preserve all interaction/a11y/state specs. Flag for responsive rule review if moved to different layout region. |
| Component RESTYLED | Update design token values in tokens.md | Preserve interaction behaviors. Update contrast ratios in tokens.md. |
| Component ADDED by designer | Create new JSON node with `tag: "NEW"` | Generate PLACEHOLDER interaction/a11y/state specs tagged `[DESIGNER_ADDED — NEEDS_BEHAVIORAL_SPEC]`. |
| Component REMOVED by designer | Remove from all 3 artifacts | Remove associated interaction/a11y/state entries from tokens.md. Log removal in changelog. |
| Component RESIZED | Update `spatial_hint` dimensions | Preserve behaviors. Flag for responsive rule review if size change crosses breakpoint thresholds. |
| Text content CHANGED | Update in JSON props and SVG text | Preserve all behavioral specs. Update ARIA labels if text was a label. |

**Step 4: Regenerate artifacts**
- Updated spatial-layout.json with merged component tree
- Updated wireframe.svg regenerated from new positions (or captured from Figma via `get_screenshot` as SVG export)
- Updated tokens.md with:
  - New design token values (from Figma)
  - Preserved interaction behaviors (from original)
  - Preserved accessibility specs (from original)
  - Preserved state definitions (from original)
  - `[DESIGNER_ADDED]` placeholders for new components
  - Changelog section at the top

**Step 5: Validation**
- Run ID-linkage validation (all IDs present in all 3 artifacts)
- Flag `[DESIGNER_ADDED]` items for implementation agent attention
- Generate changelog: what the designer changed, what behavioral specs were preserved, what needs review

### Token budget comparison:

| Approach | Conversion Cost | Implementation Agent Read Cost | Total | Fidelity |
|----------|----------------|-------------------------------|-------|----------|
| Option 1: Diff | ~8-15k | ~12-28k (diff + original) | ~20-43k | Low-Medium |
| Option 2: Regen | ~15-25k | ~10-24k (updated manifest only) | ~25-49k | **Highest** |
| Option 3: HTML | ~5-10k | ~15-30k (HTML + original tokens) | ~20-40k | Low |

Option 2's conversion step is more expensive, but the implementation agent reads ONE authoritative artifact set instead of juggling two formats. Over multiple implementation agents reading the same design (e.g., parallel story implementation), the per-read efficiency compounds.

### Why this maximizes design intent:

1. **Same format throughout** — no format conversion at consumption time
2. **Behavioral specs preserved by default** — interaction/a11y/state specs carry forward automatically
3. **Designer changes are MERGED, not APPENDED** — the updated manifest is a complete, self-consistent specification
4. **Explicit flags for gaps** — `[DESIGNER_ADDED]` markers tell the implementation agent exactly where behavioral specs are incomplete
5. **ID-linkage maintained** — cross-referencing works across all 3 artifacts
6. **Changelog provides context** — implementation agent can prioritize reviewing designer-changed areas
