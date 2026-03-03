# Epic Complexity Evaluator

Classify a beads epic as SIMPLE, MODERATE, or COMPLEX to determine the decomposition path.

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

**SIMPLE** — ALL of these must be true:
- Estimated source files to modify (excl. tests): **≤ 3**
- Architectural layers touched: **≤ 1**
- Interface/class signature changes: **0**
- No qualitative overrides triggered
- Done definitions: **present** (requirements are specific enough to write tasks now)
- Single concern: **yes**
- Confidence in estimates: **high** (you found the specific files and verified layer boundaries)

**MODERATE** — ALL of these must be true (and COMPLEX not triggered):
- Estimated source files to modify (excl. tests): **≤ 8**
- Architectural layers touched: **≤ 2**
- Interface/class signature changes: **0**
- No qualitative overrides triggered
- Single concern: **yes** (once clarified)
- At least one of: done definitions missing OR confidence is medium on file estimates

**COMPLEX** — ANY of these:
- Estimated source files > 8
- Architectural layers ≥ 3
- Interface/class signature changes ≥ 1
- Any qualitative override triggered
- Single concern: no (multiple vertical slices needed)
- Can't estimate architectural layers (ambiguity too deep)

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
