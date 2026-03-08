# Complexity Evaluator

Classify a ticket story as TRIVIAL or COMPLEX to determine whether `/implementation-plan` should run.

## Input

Story ID passed as argument.

## Process

### 1. Load Context

```bash
tk show <story-id>
```

Extract the parent epic ID from the `parent` field. If a parent exists:

```bash
tk show <parent-epic-id>
```

Note any preplanning split-candidate flags or risk register entries from the story/epic descriptions.

### 2. Find Story-Specific Files (for context only)

Grep/Glob for files specifically mentioned or implied by the story description (class names, function names, routes, models). This step is to locate relevant codebase context for the story — not for rubric scoring. The shared rubric performs all dimension counting.

### 3. Delegate to Shared Rubric

Load the shared rubric dimensions from `lockpick-workflow/skills/shared/prompts/complexity-evaluator.md` before scoring. Apply those dimension thresholds and scope_certainty guidance. Map your result to this file's output tier schema.

**Sprint routing rule**: If the shared rubric returns MODERATE, classify this story as COMPLEX for /sprint. The sprint workflow escalates MODERATE to COMPLEX for safety — triggering /implementation-plan ensures no planning gaps before sub-agents execute.

**TRIVIAL** — ALL dimension thresholds met (per shared rubric), no qualitative overrides triggered, confidence high.

**COMPLEX** — ANY quantitative threshold exceeded, any qualitative override triggered, confidence is medium, OR shared rubric returns MODERATE.

### 4. Output

Return a single JSON block:

```json
{
  "classification": "TRIVIAL",
  "confidence": "high",
  "files_estimated": ["src/models/config.py"],
  "test_files_estimated": ["tests/unit/test_config.py"],
  "layers_touched": ["Service"],
  "interfaces_affected": 0,
  "qualitative_overrides": [],
  "reasoning": "Single config field addition in existing model, one test file, no interface changes"
}
```

**Rules:**
- When confidence is "medium", classification MUST be "COMPLEX"
- When any qualitative override is triggered, classification MUST be "COMPLEX"
- When shared rubric returns MODERATE, classification MUST be "COMPLEX" (sprint routing rule)
- List qualitative overrides by name (e.g., `["ambiguity", "new_pattern"]`)
- `reasoning` should be one sentence explaining the classification
- Do NOT modify any files — this is analysis only
