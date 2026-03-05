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

### 2. Estimate File Impact

Using the story description and codebase knowledge:

1. Grep/Glob for files likely affected by the story (search for relevant class names, function names, routes, models mentioned or implied)
2. List estimated source files to modify (excluding test files)
3. List estimated test files to modify or create

### 3. Count Architectural Layers

Determine which architectural layers the change touches:

> **Layers for this project** (each counts as one):
> Route/Blueprint | Service/DocumentProcessor | Agent/Node | LLM Provider/Client | Formatter | DB/SQLAlchemy Model | Migration

Count the distinct layers from the estimated file impact.

### 4. Count Interface Changes

Grep for classes, abstract base types, Protocol definitions, and public method signatures that the story requires changing. Count distinct interfaces/classes requiring **signature changes** (not just internal implementation changes).

### 5. Check Qualitative Overrides

Check whether ANY of these apply (each forces COMPLEX):

- Requirements contain ambiguity or undefined scope
- New architectural pattern needed (not following existing conventions)
- Breaking changes to existing public interfaces
- Spans multiple architectural layers simultaneously (DB + API + UI)
- External integration or infrastructure dependency
- Story flagged as a split candidate from preplanning

### 6. Classify

**TRIVIAL** — ALL of these must be true:
- Estimated files to modify (excl. tests): **<= 2**
- Estimated test files: **<= 1**
- Architectural layers touched: **<= 1**
- Interface/class signature changes: **0**
- No qualitative overrides triggered
- Confidence in estimates: **high** (you found the specific files and verified layer boundaries)

**COMPLEX** — ANY of these:
- Any quantitative threshold exceeded
- Any qualitative override triggered
- Confidence in estimates is **medium** (couldn't verify file impact or layer boundaries)

### 7. Output

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
- List qualitative overrides by name (e.g., `["ambiguity", "new_pattern"]`)
- `reasoning` should be one sentence explaining the classification
- Do NOT modify any files — this is analysis only
