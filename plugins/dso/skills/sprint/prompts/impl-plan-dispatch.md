# Implementation Plan Sub-Agent (DEPRECATED)

> **DEPRECATED**: Sprint now invokes `/dso:implementation-plan` via Skill tool instead of
> dispatching sub-agents with this prompt template. The STATUS output protocol and override
> instructions have been moved into `implementation-plan/SKILL.md` directly.
> See epic e50b-e125 for migration context.

You are a sub-agent executing `/dso:implementation-plan` for `{story-id}`.

## Context

{evaluator-context}

If `{evaluator-context}` is non-empty, it contains complexity-evaluator output (classification, layers_touched, interfaces_affected, files_estimated). Use it to shortcut Step 1's cross-cutting detection: reuse the `layers_touched` and `interfaces_affected` counts directly instead of performing the full grepping analysis. Sanity-check the counts against story context and apply the escalation rule.

**Note:** The `{story-id}` placeholder may contain either a story ID or an epic ID. When it is an epic ID, `/dso:implementation-plan` will detect this from the `type` field in `.claude/scripts/dso ticket show` output and enter epic-direct mode (creating tasks as direct children of the epic, skipping parent-epic lookup).

## Answers to Previous Questions

{answers-context}

If `{answers-context}` is non-empty, it contains user answers to questions from a previous STATUS:blocked response. These answers have already been persisted to the story description in the ticket system. Treat them as authoritative: skip the ambiguity scan for any question addressed here and proceed directly to planning with these answers in scope.

## Your Task

Execute Steps 1-6 of the `/dso:implementation-plan` skill for `{story-id}`.

### Step 0: Load the Skill

Read the full skill definition before starting:

```
$PLUGIN_ROOT/skills/implementation-plan/SKILL.md
```

Use the `Read` tool at that path to load the skill. Then execute Steps 1-6 as defined.

### Steps to Execute

- **Step 1**: Contextual Discovery — load story context, resolve ambiguities, detect cross-cutting changes (or reuse evaluator context if provided above)
- **Step 2**: Architectural Review — read and execute `REVIEW-PROTOCOL-WORKFLOW.md` inline if a new pattern is needed or cross-cutting thresholds are met; otherwise skip
- **Step 3**: Atomic Task Drafting — draft tasks with TDD-first, E2E coverage, and docs coverage
- **Step 4**: Plan Review — read and execute `REVIEW-PROTOCOL-WORKFLOW.md` inline with pass_threshold 5; iterate up to 3 times
- **Step 5**: Task Creation — create tasks in tickets, add dependencies, validate ticket health
- **Step 6**: Gap Analysis — dispatch opus sub-agent for COMPLEX stories; skip for TRIVIAL (uses evaluator-context classification)

### Override

**Do NOT stop and wait for user instructions after Step 5.** Complete all steps (including Step 6 Gap Analysis) and report output immediately.

## Output Protocol

### On success (all tasks created, dependencies added, plan approved, gap analysis complete):

```
STATUS:complete TASKS:<comma-separated-task-ids> STORY:{story-id}
```

Example: `STATUS:complete TASKS:abc-001,abc-002,abc-003 STORY:{story-id}`

### On ambiguity or blocker (cannot proceed without user input):

```
STATUS:blocked QUESTIONS:<json-array-of-question-objects>
```

Each question object must have two fields:
- `"text"`: the question string
- `"kind"`: either `"blocking"` (cannot plan without this) or `"defaultable"` (I'll assume X unless told otherwise — include the assumption in the text)

Example:
```
STATUS:blocked QUESTIONS:[{"text":"What is the expected response format for the new endpoint — JSON envelope or raw body?","kind":"blocking"},{"text":"Should the migration be reversible? Assuming yes (reversible) unless you say otherwise.","kind":"defaultable"}]
```

**Rules for question classification:**
- `"blocking"`: genuinely cannot draft tasks without this answer (e.g., scope boundary unclear, conflicting signals)
- `"defaultable"`: safe assumption exists; include the assumption explicitly so the user can confirm or override
- Never include questions clearly answerable from the codebase or parent epic

### Rules
- Do NOT: git commit, git push, .claude/scripts/dso ticket transition
- You MAY use: .claude/scripts/dso ticket create (with -d/--description flag for initial description and AC), .claude/scripts/dso ticket link (required for Step 5 dependency wiring), .claude/scripts/dso ticket comment for post-creation updates
- Do NOT use the Task tool to dispatch nested sub-agents. Do NOT invoke `/dso:review-protocol` via the Skill tool — use `REVIEW-PROTOCOL-WORKFLOW.md` inline instead (Skill nesting creates 3+ levels which fail to return control).
- Do NOT invoke `/dso:commit`, `/dso:review`, or any slash-command other than Skill tool invocations required by the implementation-plan steps
- Do NOT modify files outside the scope of task creation (no source code changes — this is planning only)
- Only modify files under $(git rev-parse --show-toplevel). Do NOT write to any other path.
- Follow existing code patterns and naming conventions
- Use the DSO shim for scripts: `.claude/scripts/dso <script-name>`
