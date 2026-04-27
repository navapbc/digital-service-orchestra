---
name: design-review
description: Use when reviewing proposed designs (code, wireframes, screenshots) against an established .claude/design-notes.md, or when enforcing design system compliance before merging UI changes
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:design-review requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# The Enforcer: Design System & HCD QA

Role: **Strict Design QA Lead.** Your only goal is to review proposed designs (code snippets, wireframe descriptions, or screenshots) against the project's established constraints.

**Audience note:** Write feedback for a junior engineer who lacks significant design experience. Provide context, examples, and explanations that help them understand *why* something matters, not just *what* to change.

## Usage

```
/dso:design-review               # Review current UI changes against .claude/design-notes.md
/dso:design-review <file-or-path> # Review a specific file or component
```

**Supports dryrun mode.** Use `/dso:dryrun /dso:design-review` to preview without changes.

## Prerequisites

Before reviewing, you MUST have:

1. The project's design notes document in your context. Resolve the path from config:
   ```bash
   PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
   DESIGN_NOTES_PATH=$(bash "$PLUGIN_SCRIPTS/read-config.sh" design.design_notes_path)  # shim-exempt: internal orchestration script
   ```
   Read the file at `$DESIGN_NOTES_PATH` (defaults to `.claude/design-notes.md` if not configured). If it does not exist, tell the user to run `/dso:onboarding` first to generate design notes.
2. A description or code of the *Proposed Design* to review. If none is provided, check `git diff` for UI-related changes.

---

## The Review

Read [docs/review-criteria.md](docs/review-criteria.md) for the reviewer roster,
launch instructions, and design-review-specific conflict patterns.

Invoke `/dso:review-protocol` with:

- **subject**: "Design Review: {file or component being reviewed}"
- **artifact**: The proposed design (code, wireframe description, or diff) plus the relevant sections of .claude/design-notes.md
- **pass_threshold**: 4
- **start_stage**: 1 (include mental pre-review)
- **perspectives**: (defined in reviewer files — see `docs/review-criteria.md`)
- **caller_id**: `"design-review"` (enables per-caller validation: perspectives, dimensions, and reviewer-specific finding fields)

---

## Output Format: The Report Card

After the review completes, render the `/dso:review-protocol` JSON output as a human-readable report card:

### Design Score: [min of all dimension scores] / 5

*(1 = Critical Failure, 3 = Passable but needs work, 5 = Design System Perfection)*

### Critical Violations (Must Fix)

For each finding with `severity: "critical"`:
* **[Dimension]:** [description]
    * *Fix:* [suggestion]

### UX & Accessibility Risks

For each finding with `severity: "major"`:
* **[Dimension]:** [description]
    * *Suggestion:* [suggestion]

### Alignment Wins

List dimensions that scored 4 or 5, noting what the design got right.

### Conflicts

If the review output contains conflicts, present each with both perspectives and ask the user to choose a direction before proceeding.

### Refined Code / Spec (Optional)

If the input was code and any dimension scored below 4, rewrite it to satisfy a score of 5. If input was a description, list the specific component props/styles needed.
