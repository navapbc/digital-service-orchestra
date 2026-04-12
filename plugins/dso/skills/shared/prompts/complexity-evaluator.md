# Shared Complexity Evaluator

> **DEPRECATED**: The canonical source for complexity evaluation is now `agents/complexity-evaluator.md`. Callers should dispatch via the `dso:complexity-evaluator` named agent (using `subagent_type`) or read the agent definition file directly. This shared rubric file is retained as reference documentation only.

Classify a ticket as TRIVIAL, MODERATE, or COMPLEX to determine routing in `/dso:debug-everything` and `/dso:sprint`.

## Input

Ticket ID passed as argument. Load the ticket via: `.claude/scripts/dso ticket show <ticket-id>`

## Five-Dimension Rubric

Apply these dimensions to every ticket:

### Dimension 1: Files

Estimated source files to change (excluding test files).

| Count | Signal |
|-------|--------|
| ≤ 1 | Toward TRIVIAL |
| 2–3 | Toward MODERATE |
| > 3 | Toward COMPLEX |

### Dimension 2: Layers

Count distinct architectural layers touched. For this project, layers are:
Route/Blueprint | Service/DocumentProcessor | Agent/Node | LLM Provider/Client | Formatter | DB/SQLAlchemy Model | Migration

For skill/prompt files, plugin scripts, and documentation: treat as 0 architectural layers.

| Count | Signal |
|-------|--------|
| ≤ 1 | Toward TRIVIAL |
| 2 | Toward MODERATE |
| ≥ 3 | Toward COMPLEX |

### Dimension 3: Interfaces

Count interface/class signature changes (public method signatures on classes, Protocols, or abstract base types). Internal implementation changes only do not count.

| Count | Signal |
|-------|--------|
| 0 | Neutral |
| ≥ 1 | Forces COMPLEX |

### Dimension 4: scope_certainty

How completely the ticket specifies what is wrong/required and what a correct solution looks like.

**Disambiguation**: If the ticket `type` field is absent, blank, or unrecognized, treat scope_certainty as **Low** and classify COMPLEX.

#### For `type: bug` tickets

| Rating | Criteria |
|--------|---------|
| High | The failure condition is clearly described with a reproduction path; the fix scope is bounded (specific file, function, or behavior to change); a correct post-fix behavior is stated |
| Medium | The failure is described but either the reproduction path is unclear OR the fix scope is uncertain (might require changes in more than one place) |
| Low | The failure is vague, reproduction unknown, or fix scope spans unknown layers |

**Worked examples — bug tickets:**

Example B-1 (High): `"redis_cache_miss_rate_endpoint returns 500 when cache key contains ':'. Repro: POST /api/cache/stats with key='a:b'. Expected: 200 with empty stats. Fix: sanitize ':' in key before Redis call in CacheService.get_stats()."`
→ Clear repro, bounded scope, correct behavior stated. scope_certainty: High.

Example B-2 (Medium): `"Users sometimes see stale extraction results after re-uploading the same document. Unclear if it's a cache issue, a job_store race condition, or a DB write ordering problem."`
→ Failure described, but root cause uncertain across multiple potential layers. scope_certainty: Medium.

Example B-3 (Low): `"The pipeline sometimes crashes. Need to investigate."`
→ No repro, no fix scope. scope_certainty: Low → forces COMPLEX.

#### For `type: story`, `type: epic` tickets

| Rating | Criteria |
|--------|---------|
| High | Acceptance criteria are specific enough to write a failing test before coding; file paths or interfaces are named; done definition is measurable |
| Medium | The goal is clear but acceptance criteria are implicit or partially specified; a developer would need to make assumptions |
| Low | Requirements are ambiguous, acceptance criteria are absent, or the scope is described in business terms only with no technical specifics |

**Worked examples — feature/story/epic tickets:**

Example F-1 (High): `"Add a /api/v1/rules/{id}/complexity endpoint that returns {rule_id, complexity_score, computed_at}. Test: GET /api/v1/rules/123/complexity → 200 {rule_id: 123, complexity_score: 0.75, computed_at: '...'}. Files: routes/rules_routes.py, services/rule_service.py, tests/unit/test_rules_routes.py."`
→ Named files, test specified, measurable acceptance. scope_certainty: High.

Example F-2 (Medium): `"Allow users to filter rules by complexity score on the review page. Add a filter input. High/Medium/Low bands."`
→ Goal clear, but threshold values and component names not specified; developer needs to decide. scope_certainty: Medium.

Example F-3 (Low): `"Improve the rule extraction quality." (no acceptance criteria, no files, no measurable done definition)`
→ Ambiguous, no technical specifics. scope_certainty: Low → forces COMPLEX.

### Dimension 5: Confidence

The evaluating agent's confidence in its own estimates.

| Level | Meaning |
|-------|---------|
| High | Specific files found via Grep/Glob; layer boundaries verified |
| Medium | Estimates based on description alone; could not locate specific files |

## Classification Rules

| Tier | Criteria |
|------|---------|
| **TRIVIAL** | ALL: files ≤ 1, layers ≤ 1, interfaces = 0, scope_certainty = High, confidence = High |
| **MODERATE** | ALL: files ≤ 3, layers ≤ 2, interfaces = 0, scope_certainty = High or Medium, confidence = High; AND no COMPLEX qualifier applies |
| **COMPLEX** | ANY: files > 3, layers ≥ 3, interfaces ≥ 1, scope_certainty = Low, confidence = Medium on TRIVIAL/MODERATE estimate |

Promotion rules:
- TRIVIAL + scope_certainty Medium → MODERATE
- confidence Medium on any TRIVIAL/MODERATE estimate → COMPLEX
- scope_certainty Low → COMPLEX (always, regardless of other signals)
- interfaces ≥ 1 → COMPLEX (always)

## Context-Specific Routing

The shared rubric outputs TRIVIAL, MODERATE, or COMPLEX. How MODERATE is handled depends on the calling context:

| Calling skill | MODERATE routing | Reason |
|---|---|---|
| `/dso:sprint` story evaluator | Escalate → **COMPLEX** | Ensures /dso:implementation-plan runs; prevents planning gaps before sub-agent execution |
| `/dso:sprint` epic evaluator | Escalate → **COMPLEX** | Preserves full preplanning when scope is not fully certain |
| `/dso:debug-everything` complexity gate | De-escalate → **TRIVIAL** | Enables autonomous fix dispatch; MODERATE bugs are well-understood enough for a single fix sub-agent |
| `/dso:brainstorm` Phase 3 Step 4 | TRIVIAL → `/dso:implementation-plan`; MODERATE+High → `/dso:preplanning --lightweight`; MODERATE+Medium → `/dso:preplanning --lightweight`; COMPLEX → `/dso:preplanning` | TRIVIAL epics already have task-level detail from brainstorm. MODERATE+High runs a lightweight risk/scope scan before implementation planning. MODERATE+Medium needs lightweight decomposition for implicit acceptance criteria. COMPLEX always needs full story decomposition |
| `/dso:fix-bug post-investigation` | TRIVIAL/MODERATE proceed to fix, COMPLEX creates epic | Post-investigation evaluation when fix scope is known |

Calling skills are responsible for applying their own routing rule to the shared rubric's output. The shared rubric always outputs the raw classification; callers decide final routing.

## Output Schema

**Note for delegating evaluators**: This output schema (TRIVIAL/MODERATE/COMPLEX) applies when the shared rubric is used directly. If you are reading this file because a delegating evaluator instructed you to "Load the shared rubric dimensions from this file," apply only the dimension thresholds and scope_certainty guidance above. Use the output tier schema defined in your calling evaluator file (which may use different tier names such as SIMPLE/MODERATE/COMPLEX for epic-level evaluation). The delegation instruction "Map your result to this file's output tier schema" in your calling evaluator takes precedence over this schema section.

Return a single JSON block:

```json
{
  "classification": "TRIVIAL|MODERATE|COMPLEX",
  "confidence": "high|medium",
  "files_estimated": ["path/to/file.py"],
  "layers_touched": ["Service", "Route"],
  "interfaces_affected": 0,
  "scope_certainty": "High|Medium|Low",
  "qualitative_overrides": [],
  "reasoning": "One sentence explaining the classification."
}
```

**Rules:**
- `classification` MUST be exactly one of: TRIVIAL, MODERATE, COMPLEX (not SIMPLE)
- When confidence is "medium" on a TRIVIAL or MODERATE estimate, classification MUST be "COMPLEX"
- When scope_certainty is "Low", classification MUST be "COMPLEX"
- When interfaces_affected ≥ 1, classification MUST be "COMPLEX"
- List qualitative overrides by name (e.g., `["scope_certainty_low", "interface_change"]`)
- `reasoning` should be one sentence
- Do NOT modify any files — this is analysis only
