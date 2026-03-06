---
name: design-onboarding
description: Use when starting a new project or feature that needs a design system foundation, visual language definition, or when the team needs a shared "North Star" design document before implementation begins
user-invocable: true
---

# Design Onboarding: North Star Definition

Role: **Senior Design Systems Lead** with deep expertise in Human-Centered Design (HCD), WCAG 2.1+ Accessibility, and Component-Driven Architecture.

**Goal:** Conduct a structured intake interview with the user to generate a `DESIGN_NOTES.md` file. This file serves as the **Immutable Source of Truth** for all future design, engineering, and QA agents working on this project.

## Config Resolution (reads project workflow-config.yaml)

At activation, load the design system name via read-config.sh before executing any steps:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
DESIGN_SYSTEM_NAME=$(bash "$PLUGIN_SCRIPTS/read-config.sh" design.system_name 2>/dev/null || echo "")
```

Resolution order used by `read-config.sh`:
1. `workflow-config.yaml` at `$(pwd)/workflow-config.yaml` (project root — most common)
2. Fallback: empty string (no design system configured — use generic prompts)

If `DESIGN_SYSTEM_NAME` is non-empty, use it to populate example text and defaults throughout the interview and template. If empty, use generic placeholders (e.g., "your design system" instead of a specific name).

## Usage

```
/design-onboarding          # Start the full onboarding flow
```

**Supports dryrun mode.** Use `/dryrun /design-onboarding` to preview without changes.

## Workflow Overview

```
Flow: Phase 1 (Intake Interview) -> Phase 2 (File Generation)
  Step 1: Strategy & User -> Step 2: The Experience (HCD) -> Step 3: The System (UI/Dev)
  -> Compile into DESIGN_NOTES.md -> User reviews -> Done
```

---

## Phase 1: The Intake Interview (/design-onboarding)

**Do not dump all questions at once.** Engage the user in a step-by-step extraction process to ensure high-fidelity answers. Use `AskUserQuestion` for each step.

### Step 1: Strategy & User (/design-onboarding)

Ask these questions one group at a time:

* **The Vision:** "In one sentence, what is the specific value proposition of this application? (e.g., 'Reduces tax filing time by 50% for freelancers')."
* **The Users:** "Define 2-3 specific User Archetypes. Not just demographics, but *behaviors* (e.g., 'The Panicked Auditor' vs. 'The Relaxed Browser')."
* **Success Metrics:** "How will we know the design is successful? (e.g., Speed of completion, Low error rates, Discoverability?)"

### Step 2: The Experience (HCD) (/design-onboarding)

* **Golden Paths:** "What are the top 2 workflows that *must* be frictionless? Describe them step-by-step."
* **Anti-Patterns:** "What do we explicitly want to AVOID? (e.g., 'No pop-ups', 'No endless scrolling', 'No dark patterns')."

### Step 3: The System (UI/Dev) (/design-onboarding)

* **Tech Stack:** "What is the specific UI library/framework? (e.g., React + Tailwind + Shadcn/UI, or Angular + Material)."
* **Design System / Component Library:** "Are you using an established design system or component library? (e.g., Material UI, Ant Design, Bootstrap, Chakra UI, a custom design system, or none)." If yes, this changes how visual tokens are defined — tokens, colors, spacing, typography, and icons should all derive from the design system rather than being defined from scratch. Note this in the generated file.
  - **If `DESIGN_SYSTEM_NAME` is configured:** Pre-fill this answer with the configured value and confirm with the user: "Your project is configured to use **{DESIGN_SYSTEM_NAME}**. Is this still correct, or has the design system changed?"
* **Visual Language:** "Describe the vibe in 3 adjectives (e.g., 'Trustworthy, Dense, Clinical' or 'Playful, Round, Airy')."
* **Accessibility Target:** "Is the target WCAG AA or AAA?"

---

## Phase 2: File Generation (/design-onboarding)

Once the interview is complete, compile the answers into `DESIGN_NOTES.md` using the template below. Use Markdown strictly. Write the file to the project root.

### DESIGN_NOTES.md Template

```markdown
# DESIGN_NOTES.md (Project North Star)

## 1. Strategic Vision
> **Core Value:** [Insert 1-sentence Vision]
> **Primary Goal:** [Insert Success Metric, e.g., "Optimize for speed of data entry"]

## 2. User Archetypes
| Archetype | Mindset/Behavior | Critical Need | Friction Risk |
| :--- | :--- | :--- | :--- |
| **[Name]** | [e.g., Rushing, Low-tech] | [Specific Goal] | [What annoys them?] |
| **[Name]** | [e.g., Power user, Analyst] | [Specific Goal] | [What annoys them?] |

## 3. Design Principles & Heuristics
* **Tone of Voice:** [e.g., Professional, reassuring, concise]
* **Interaction Model:** [e.g., "Wizard-style steps" or "Single-page Dashboard"]
* **Anti-Patterns (DO NOT DO):**
    * [Constraint 1]
    * [Constraint 2]

## 4. Golden Paths (Critical User Journeys)
1. **[Path Name]:** [Step 1] -> [Step 2] -> [Success State]
2. **[Path Name]:** [Step 1] -> [Step 2] -> [Success State]

## 5. System Architecture
* **Tech Stack:** [Framework] + [UI Library]
* **Component Library:** [Design system name and version, or "None (custom)"] — If a design system is specified, all UI components, layout, and tokens should come from it. Do NOT introduce custom components when the design system provides an equivalent.
* **Accessibility Standard:** [e.g., WCAG 2.1 AA]
* **Responsiveness:** [e.g., Mobile-first or Desktop-centric]

## 6. Visual Tokens (The "Vibe")
> **Note:** If a design system is specified in Section 5, tokens below should reference that system's token names rather than defining custom values. For example, use `primary` / `error` token names from the design system, not raw hex colors.

* **Design System:** [e.g., "All tokens derive from {DESIGN_SYSTEM_NAME}" or "Custom tokens defined below"]
* **Spacing Strategy:** [e.g., Compact/Dense for data or Spacious/Airy for content. Reference design system spacing units if applicable.]
* **Shape Language:** [e.g., Fully rounded (20px), Slight radius (4px), or Sharp (0px). Follow design system defaults if applicable.]
* **Color Logic:**
    * *Primary Action:* [Describe intent, e.g., "High contrast Blue" or design system token name]
    * *Semantic Success:* [Describe intent, e.g., design system `success` token]
    * *Semantic Warning:* [Describe intent, e.g., design system `warning` token]
    * *Semantic Error:* [Describe intent, e.g., "Soft Red background, dark Red text" or design system `error` token]
* **Typography:** [Font stack or design system type scale reference]
* **Icons:** [Icon source, e.g., design system icon sprite, Material Icons, Lucide, etc.]

## 7. Change Log
* [Date] - Initial North Star definition established.
```

**Config-driven defaults:** When `DESIGN_SYSTEM_NAME` is set, pre-fill the "Component Library" field in Section 5 and the "Design System" field in Section 6 with the configured value. The user can override during review.

### After Generation

Present the generated `DESIGN_NOTES.md` to the user and ask:

> "Does this North Star document accurately capture our design intent? What should we adjust before we lock this in as the source of truth?"

Revise until the user explicitly approves.
