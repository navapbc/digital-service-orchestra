# Design Manifest

## Meta

| Field | Value |
|-------|-------|
| **Design ID** | `{DESIGN_UUID}` |
| **Story ID** | `{STORY_ID}` |
| **Story Title** | {STORY_TITLE} |
| **Created** | {YYYY-MM-DD} |
| **Status** | {DRAFT / IN_REVIEW / APPROVED / REVISION_N} |
| **Review Cycles** | {N} |

---

## Story Context

> {STORY_DESCRIPTION — paste the full story description here}

### Acceptance Criteria

{List acceptance criteria from the story, or note "None specified" if absent}

### Success State

{One clear paragraph describing what "done" looks like for the user — the
"After" experience. This is the north star for the design.}

---

## Epic Context

{If the story belongs to a parent epic, complete this section. If standalone,
write: "This is a standalone story with no parent epic."}

| Field | Value |
|-------|-------|
| **Epic ID** | `{EPIC_ID}` |
| **Epic Title** | {EPIC_TITLE} |
| **Epic Vision** | {1-2 sentence summary of the epic's overall goal} |

### Sibling Story Designs

| Story ID | Title | Design Status | Design UUID | Key UX Decisions |
|----------|-------|---------------|-------------|-----------------|
| {id} | {title} | {Designed / Not yet designed} | {uuid or —} | {brief summary of layout, components, patterns chosen} |

### Epic UX Map

{Describe how this story's design fits within the epic's unified user
experience. Explain which parts of the overall UX this story owns, how it
connects to sibling stories' designs, and any shared navigation, layout, or
component decisions that span stories.}

### Cross-Story Dependencies

{List any components, patterns, or design tokens introduced by sibling story
designs that this design reuses. Also note any components this design introduces
that sibling stories may need to adopt.}

---

## Design Rationale

### User Problem

{One sentence stating the core user problem this design solves.}

### Interaction Heuristic Evaluation

| Interaction | Consequence | Frequency | Cognitive Load | Design Implication |
|-------------|-------------|-----------|----------------|-------------------|
| {user action 1} | {High/Low} | {High/Low} | {High/Low} | {What this means for the UI} |
| {user action 2} | {High/Low} | {High/Low} | {High/Low} | {What this means for the UI} |

### Scope Assessment

- **Foundation UX**: {Description of the simplest version using only EXISTING components}
- **Ideal UX**: {Description of the best version, potentially with NEW/MODIFIED components}
- **Decision**: {Ship Foundation only / Ship Ideal / Split into Foundation + Enhancement}
- **Split rationale**: {If split: why the Ideal requires a separate story}

---

## Component Mapping

| Element ID | Component | Tag | Design System Ref | Notes |
|------------|-----------|-----|-------------------|-------|
| {id} | {ComponentName} | EXISTING | {path} | {usage notes} |
| {id} | {ComponentName} | MODIFIED | {path} | {what changes and why} |
| {id} | {ProposedName} | NEW | — | {justification for new component} |

### Reuse Summary

- **Existing**: {X} components ({N}%)
- **Modified**: {Y} components ({N}%)
- **New**: {Z} components ({N}%)

---

## Design Artifacts

| Artifact | File | Purpose |
|----------|------|---------|
| Spatial Layout Tree | `designs/{uuid}/spatial-layout.json` | Hierarchical DOM structure and component configuration |
| Functional Blueprint | `designs/{uuid}/wireframe.svg` | Visual spatial arrangement and proportions |
| Design Token Overlay | `designs/{uuid}/tokens.md` | Behaviors, responsiveness, accessibility, tokens |
| Screenshots | `designs/{uuid}/screenshots/` | Current application state captured via Playwright |

---

## Implementation Strategy

The implementation agent should consume these artifacts using the **ID-Linkage
Method**. Every element has a consistent `id` across all three artifacts.

1. **Structure** (JSON): Build the component tree from `spatial-layout.json`.
   Import EXISTING components from the design system. Create NEW components
   per their specifications. Apply props and ARIA attributes.

2. **Layout** (SVG): Reference `wireframe.svg` as XML to extract spatial
   relationships. Translate element positions into CSS flex/grid layout rules.
   Note groupings for container relationships.

3. **Behavior** (Tokens): Apply `tokens.md` for interaction handlers, responsive
   breakpoint rules, accessibility patterns, and state management. Map design
   token names to the project's actual token values.

4. **Verify**: Cross-reference element IDs across all three artifacts. Every ID
   should appear in all three. Flag any discrepancies before coding.

### State Changes

| State | Trigger | Visual Description | ARIA Announcement |
|-------|---------|-------------------|-------------------|
| Default | Page load | {describe default appearance} | — |
| Loading | {trigger} | {describe loading state} | {screen reader announcement} |
| Success | {trigger} | {describe success state} | {screen reader announcement} |
| Error | {trigger} | {describe error state} | {screen reader announcement} |
| Empty | {trigger} | {describe empty state} | {screen reader announcement} |

---

## Accessibility Assertions

These MUST be verified during implementation:

- [ ] **WCAG {criterion}**: {Specific testable assertion}
- [ ] **Keyboard**: {Full keyboard navigation description — tab order, shortcuts}
- [ ] **Screen reader**: {Expected announcement behavior for key interactions}
- [ ] **Reduced motion**: {What happens when prefers-reduced-motion is enabled}
- [ ] **High contrast**: {What happens in forced-colors/high-contrast mode}
- [ ] **Touch targets**: {All interactive elements meet 44x44px minimum}

---

## UX Friction Review

| Potential Pain Point | How This Design Addresses It |
|---------------------|------------------------------|
| {pain point 1} | {specific solution in this design} |
| {pain point 2} | {specific solution in this design} |

---

## Playwright Review Notes

{If Playwright was used: summarize what was observed in the current application
state and how it informed design decisions.}

{If Playwright was NOT used: note "Live application review was not performed.
Design is based on source code analysis only." and list any assumptions that
should be validated.}

---

## Review History

See `designs/{uuid}/review-log.md` for the full review history with scores,
feedback, and revision notes for each cycle.

**Final result**: {APPROVED on cycle N / APPROVED after user guidance / PENDING}

---

## Split Stories

{If the story was split using the Pragmatic Scope Splitter:}

| Story ID | Type | Title | Description |
|----------|------|-------|-------------|
| {original ID} | Foundation | {title} | {brief description of foundation scope} |
| {new ID} | Enhancement | {title} | {brief description of enhancement scope} |

{If no split was needed: "No story split required. The design addresses the
full scope of the original story."}
