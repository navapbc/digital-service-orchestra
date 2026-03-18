# Epic Complexity Evaluator

Classify a ticket epic as SIMPLE, MODERATE, or COMPLEX to determine the decomposition path.

## Input

Epic ID passed as argument.

## Process

### 1. Load Context

```bash
tk show <epic-id>
```

Read the epic title, description, and any existing done definitions or success criteria.

### 2. Estimate File Impact

Using the epic description and codebase knowledge:

1. Grep/Glob for files likely affected by the epic (search for relevant class names, function names, routes, models mentioned or implied)
2. List estimated source files to modify (excluding test files)
3. List estimated test files to modify or create

### 3. Count Architectural Layers

Determine which architectural layers the change touches:

> **Layers for this project** (each counts as one):
> Route/Blueprint | Service/DocumentProcessor | Agent/Node | LLM Provider/Client | Formatter | DB/SQLAlchemy Model | Migration

Count the distinct layers from the estimated file impact.

### 4. Count Interface Changes

Grep for classes, abstract base types, Protocol definitions, and public method signatures that the epic requires changing. Count distinct interfaces/classes requiring **signature changes** (not just internal implementation changes).

### 5. Check Qualitative Overrides

Check whether ANY of these apply (each forces COMPLEX):

- Multiple personas: epic mentions >1 user role (admin AND end-user, developer AND PO)
- UI + backend: epic requires BOTH template/CSS changes AND service/model changes
- New DB migration: epic requires a schema migration
- Foundation/enhancement candidate: scope naturally splits into "works" vs "works well"
- External integration: epic introduces a new external API, service, or infrastructure dependency

### 6. Check Done Definitions

Determine whether the epic has measurable done definitions:
- **Present**: Epic description contains bullet-list outcomes, Gherkin-style criteria, or specific measurable conditions
- **Missing**: Epic description is vague, lacks measurable outcomes, or success criteria are implicit

### 7. Check Single Concern

Apply the one-sentence test: can you describe the change in one sentence without structural "and"?

- Structural "and" = two independent concerns: "Add config field AND update the upload page to show it"
- Incidental "and" = one concern with natural companion: "Add config field AND its validation"

### 8. Classify

Load the shared rubric dimensions from `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/complexity-evaluator.md` before scoring. Apply those dimension thresholds and scope_certainty guidance. Map your result to this file's output tier schema.

**Sprint routing rule**: If the shared rubric returns MODERATE, classify this epic as COMPLEX for /dso:sprint. This preserves the safety behavior of full preplanning when scope is not fully certain.

**File threshold note**: The shared rubric's MODERATE threshold (≤3 files) is more conservative than the old inline threshold (≤8 files). This is intentional — the tighter threshold ensures safe routing and avoids under-classifying epics with uncertain scope.

**SIMPLE** — ALL dimension thresholds met (per shared rubric), no qualitative overrides, done definitions present, single concern yes, confidence high.

**MODERATE** — Within moderate thresholds (per shared rubric), no qualitative overrides, single concern yes (once clarified), but at least one of: done definitions missing OR confidence medium on file estimates.

**COMPLEX** — ANY quantitative threshold exceeded (per shared rubric), any qualitative override triggered, single concern no, or layer count cannot be estimated.

### 9. Output

Return a single JSON block:

```json
{
  "classification": "SIMPLE",
  "confidence": "high",
  "files_estimated": ["src/agents/config.py"],
  "test_files_estimated": ["tests/unit/test_config.py"],
  "layers_touched": ["Service"],
  "interfaces_affected": 0,
  "qualitative_overrides": [],
  "missing_done_definitions": false,
  "single_concern": true,
  "reasoning": "Single config field addition, 1 layer, done definitions present, no overrides"
}
```

**Rules:**
- When confidence is "medium" on SIMPLE, classification MUST be promoted to MODERATE
- When confidence is "medium" on MODERATE, classification MUST be promoted to COMPLEX
- When any qualitative override is triggered, classification MUST be COMPLEX
- When layer count cannot be estimated, classification MUST be COMPLEX
- When file count cannot be estimated, classification MUST be at least MODERATE
- List qualitative overrides by name (e.g., `["multiple_personas", "ui_plus_backend"]`)
- `reasoning` should be one sentence explaining the classification
- Do NOT modify any files — this is analysis only
