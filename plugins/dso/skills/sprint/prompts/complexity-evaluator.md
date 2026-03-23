# Complexity Evaluator

Classify a ticket story as TRIVIAL or COMPLEX to determine whether `/dso:implementation-plan` should run.

## Input

Story ID passed as argument.

## Process

### 1. Load Context

```bash
ticket show <story-id>
```

Extract the parent epic ID from the `parent` field. If a parent exists:

```bash
ticket show <parent-epic-id>
```

Note any preplanning split-candidate flags or risk register entries from the story/epic descriptions.

### 2. Find Story-Specific Files (codebase context — not dimension scoring)

Grep/Glob for files specifically mentioned or implied by the story description (class names, function names, routes, models). The purpose of this step is twofold:

1. **Locate codebase context** so you can accurately describe the story's scope to the shared rubric.
2. **Enable high-confidence assessment** — the shared rubric's Confidence dimension (Dimension 5) requires specific files found via Grep/Glob to rate confidence as "High". If you skip file search, confidence defaults to "Medium", which forces COMPLEX classification for everything.

**What this step does NOT do**: Apply rubric thresholds or count files/layers/interfaces as dimension scores. The shared rubric in Step 3 applies all dimension thresholds (files, layers, interfaces, scope_certainty, confidence). Your job here is to find the files so the shared rubric can score them.

### 3. Delegate to Shared Rubric

Load the shared rubric dimensions from `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/complexity-evaluator.md` before scoring. Apply those dimension thresholds and scope_certainty guidance. Map your result to this file's output tier schema.

**Sprint routing rule**: If the shared rubric returns MODERATE, classify this story as COMPLEX for /dso:sprint. The sprint workflow escalates MODERATE to COMPLEX for safety — triggering /dso:implementation-plan ensures no planning gaps before sub-agents execute.

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
