# Contract: CONFIDENCE_CONTEXT Signal

- Signal Name: CONFIDENCE_CONTEXT
- Status: accepted
- Scope: onboarding Phase 0 pre-flight → Phase 2 Socratic Dialogue routing, S2 doc folder scan, S3 routing logic (story 95ca-2d8e)
- Date: 2026-04-15

## Purpose

This document defines the schema for the `CONFIDENCE_CONTEXT` object built by `/dso:onboarding` Phase 0 (pre-flight). The object captures a per-dimension confidence level for all 7 understanding areas, plus the user's declared comfort level and detected stack. It is stored in the onboarding scratchpad and consumed by downstream phases (Phase 2 Socratic Dialogue routing, S2 doc folder scan, S3 routing logic) to tailor question depth and document integration.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the emitter and parsers stay in sync across stories S1 (95ca-2d8e), S2, and S3.

---

## Signal Name

`CONFIDENCE_CONTEXT`

---

## Emitter

`skills/onboarding/SKILL.md` — Phase 0 pre-flight # shim-exempt: internal implementation path reference

The emitter:
1. Asks the user a single comfort-level question (technical / non_technical) before showing any auto-detection output.
2. Runs `detect-stack.sh` and `project-detect.sh` to collect signals.
3. Assigns a confidence level (high | medium | low) to each of the 7 understanding area dimensions based on detection output.
4. Writes the structured `CONFIDENCE_CONTEXT` object into the scratchpad as a JSON block.

The emitter MUST write a complete, valid object — all required fields must be present. A missing or malformed object is treated as all dimensions at `low` confidence by downstream parsers (fail-safe default).

---

## Parsers

- `skills/onboarding/SKILL.md` Phase 2 Socratic Dialogue — reads `dimensions` to determine question depth per area: `high` confidence → confirmation question; `low` confidence → open-ended discovery question. # shim-exempt: internal implementation path reference
- `skills/onboarding/SKILL.md` S2 doc folder scan — reads `dimensions` and `comfort_level` to decide which document folders to surface and in what order. # shim-exempt: internal implementation path reference
- `skills/onboarding/SKILL.md` S3 routing logic — reads `dimensions` and `comfort_level` to route users along the appropriate onboarding path (technical fast path vs. non-technical guided path). # shim-exempt: internal implementation path reference

All parsers must read the `CONFIDENCE_CONTEXT` object from the scratchpad's `## CONFIDENCE_CONTEXT` section before beginning their phase logic.

---

## Schema

The emitter outputs a single JSON object stored in the scratchpad under the `## CONFIDENCE_CONTEXT` section header. All fields are required.

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `dimensions` | object | Keyed by dimension name. Value is a confidence level string. All 7 dimension keys must be present. See Dimensions below. |
| `comfort_level` | string (enum) | User's declared comfort level: `"technical"` or `"non_technical"`. |
| `detected_stack` | string | Stack string returned by `detect-stack.sh` (e.g., `"node-npm"`, `"python-poetry"`, `"unknown"`). |
| `generated_at` | string (ISO timestamp) | UTC timestamp when this object was generated, in ISO 8601 format (e.g., `"2026-04-15T14:22:01Z"`). |

### Dimensions

The `dimensions` object has exactly 7 keys — one per understanding area. Each value is a confidence level string.

| Dimension Key | Understanding Area | Description |
|---|---|---|
| `stack` | Stack | Languages, frameworks, runtime versions, package managers |
| `commands` | Commands | How to build, test, lint, format, and run the project locally |
| `architecture` | Architecture | Module structure, service boundaries, data flow, key design patterns |
| `infrastructure` | Infrastructure | Hosting, deployment targets, databases, external services, secrets management |
| `ci` | CI | CI provider, pipeline stages, test gates, deployment triggers |
| `design` | Design | UI framework, design system, visual tokens, accessibility targets |
| `enforcement` | Enforcement | Linting rules, commit hooks, review gates, code style policies |

### Confidence Level Enum

Each dimension value must be one of:

| Value | Meaning | Example signal |
|---|---|---|
| `"high"` | Detection produced a clear, unambiguous answer. Parser may present for confirmation rather than asking from scratch. | `detect-stack.sh` returned `"node-npm"` with a `package.json` present and `node_modules/` directory found |
| `"medium"` | Detection produced a partial or ambiguous answer. Parser should confirm and prompt for gaps. | CI workflow files found, but multiple files exist — job names not yet confirmed |
| `"low"` | Detection produced no signal or an `"unknown"` result. Parser must ask open-ended discovery questions. | `detect-stack.sh` returned `"unknown"`, no recognized framework files found |

### Confidence Assignment Rules

| Detection outcome | Assigned level |
|---|---|
| `detect-stack.sh` returns a named stack (e.g., `"node-npm"`, `"python-poetry"`) | `stack` → `high` |
| `detect-stack.sh` returns `"unknown"` | `stack` → `low` |
| `project-detect.sh` emits a `test_dirs` value with at least one entry AND a `ci_workflow_names` entry | `commands` → `medium` (commands discovered, but user confirmation still required) |
| `project-detect.sh` emits `ci_workflow_confidence=high` AND exactly one `ci_workflow_names` entry | `ci` → `high` |
| `project-detect.sh` emits `ci_workflow_confidence=low` OR multiple `ci_workflow_names` entries | `ci` → `medium` |
| No `.github/workflows/` directory found | `ci` → `low` |
| `architecture`, `infrastructure`, `design`, `enforcement` — no automated detection exists for these areas | Default → `low` (user must describe) |

---

## Update Rules

Downstream stories S2 and S3 may **elevate** confidence levels but **never lower** them.

**Elevation is permitted when**: additional file inspection or user answers provide new, unambiguous information that justifies higher confidence for a dimension.

**Lowering is prohibited**: once a dimension is assessed at `high`, downstream stories must not change it to `medium` or `low`, even if conflicting signals emerge later. Conflicting signals should be surfaced to the user as a clarification question rather than silently downgrading confidence.

**Enforcement**: before writing an updated `CONFIDENCE_CONTEXT` to the scratchpad, downstream parsers must read the existing object and apply an element-wise max: `new_level = max(existing_level, proposed_level)` where `high > medium > low`.

---

## Scratchpad Encoding

The emitter writes the `CONFIDENCE_CONTEXT` object to the scratchpad under a dedicated section header:

```
## CONFIDENCE_CONTEXT
```json
{ ... }
```
```

Parsers locate the object by scanning for the `## CONFIDENCE_CONTEXT` section header and reading the JSON block that immediately follows.

### Canonical parsing prefix

Parsers MUST locate the object by scanning for the exact section header line:

```
## CONFIDENCE_CONTEXT
```

The JSON block begins on the line immediately after the opening fence (` ```json `) that follows the section header. All required fields must be extracted from this JSON block. No line-prefix matching applies — the parser must deserialize the full JSON object to access individual fields.

**Fail-safe**: if the `## CONFIDENCE_CONTEXT` section header is absent from the scratchpad, treat all dimensions as `"low"` and `comfort_level` as `"non_technical"`.

---

## Example

```
## CONFIDENCE_CONTEXT
```json
{
  "dimensions": {
    "stack": "high",
    "commands": "medium",
    "architecture": "low",
    "infrastructure": "low",
    "ci": "high",
    "design": "low",
    "enforcement": "low"
  },
  "comfort_level": "technical",
  "detected_stack": "node-npm",
  "generated_at": "2026-04-15T14:22:01Z"
}
```
```

**Reading this example:**
- `stack: high` — `detect-stack.sh` returned `"node-npm"` with clear signals; Phase 2 will confirm rather than ask from scratch.
- `commands: medium` — test directories found but test runner commands not yet confirmed; Phase 2 will fill the gap.
- `architecture: low` — no automated detection; Phase 2 will ask an open-ended discovery question.
- `ci: high` — single workflow file detected with `ci_workflow_confidence=high`; Phase 2 will confirm filename rather than ask.
- `comfort_level: technical` — S3 routing will use the technical fast path.

---

## Failure Contract

If the `CONFIDENCE_CONTEXT` object is:

- absent from the scratchpad (Phase 0 did not run or was interrupted),
- malformed (missing required fields, invalid JSON, unknown dimension keys),
- or contains an unrecognized `confidence_level` value for any dimension,

then the parser MUST treat all affected dimensions as `"low"` confidence. A missing `comfort_level` defaults to `"non_technical"` (safer, more guided path). A missing `detected_stack` defaults to `"unknown"`.

The parser must log a warning to the scratchpad when the object is absent or malformed so that silent degradation is detectable.

---

## Consumers

The following components emit or consume this signal:

| Component | Role | Notes |
|---|---|---|
| `skills/onboarding/SKILL.md` Phase 0 pre-flight | Emitter | Writes the complete object to the scratchpad after comfort question + detection run (story 95ca-2d8e) # shim-exempt: internal implementation path reference |
| `skills/onboarding/SKILL.md` Phase 2 Socratic Dialogue | Parser | Reads `dimensions` to select question style per area (confirmation vs. open-ended discovery) # shim-exempt: internal implementation path reference |
| `skills/onboarding/SKILL.md` S2 doc folder scan | Parser | Reads `dimensions` and `comfort_level` to prioritize and filter document folders # shim-exempt: internal implementation path reference |
| `skills/onboarding/SKILL.md` S3 routing logic | Parser | Reads `dimensions` and `comfort_level` to route along technical fast path or non-technical guided path # shim-exempt: internal implementation path reference |

All implementors must read this contract before writing Phase 0 emitter logic or Phase 2/S2/S3 parser logic. Changes to the schema require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (field removal, type changes, dimension key changes, enum value removal) require updating all emitters and parsers and this document atomically in the same commit. Additive changes (new optional fields) are backward-compatible for parsers that apply fail-safe defaults for unknown keys.

### Change Log

- **2026-04-15**: Initial version — defines CONFIDENCE_CONTEXT schema for onboarding Phase 0 pre-flight emitter → Phase 2 / S2 / S3 parsers. Establishes 7 dimension keys, three-value confidence level enum, comfort_level enum, update rules (elevation permitted, lowering prohibited), and fail-safe defaults for absent or malformed objects.
