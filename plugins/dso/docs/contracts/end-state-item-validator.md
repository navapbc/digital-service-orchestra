# Contract: end-state-item-validator

- Signal Name: end-state-item-validator
- Status: accepted
- contract_version: 1
- Scope: completion-verifier pluggable project hook interface (project → completion-verifier)
- Date: 2026-05-19

## Purpose

This document defines the contract for the `project_closure_hooks` pluggable hook mechanism in the completion-verifier. It enables host projects to register custom closure hooks that run against `## Closure Checks` items from ticket bodies, replacing the hardcoded SC9/SC13/SC14 gates in Step 3.5 with a configurable, project-specific mechanism.

---

## Signal Name

`end-state-item-validator`

---

## Emitter

Host project hook scripts, registered via the `project_closure_hooks` config key in `dso-config.conf`. The completion-verifier dispatches each registered hook and reads its output.

---

## Parser

`dso:completion-verifier` agent — reads `project_closure_hooks` from `dso-config.conf` in Step 3.5, enumerates `## Closure Checks` items from the ticket body, and dispatches each hook for each item.

---

## Configuration

In `.claude/dso-config.conf`:

```
project_closure_hooks=<hook-name-1>,<hook-name-2>
```

**When absent or empty**: the completion-verifier skips project-specific hook dispatch and runs the default SC9/SC13/SC14 gates. This is the backward-compatibility default behavior.

---

## Input Schema

Each registered hook is invoked by the completion-verifier with the following environment variables set:

| Environment Variable | Type | Required | Description |
|---|---|---|---|
| `ITEM_TEXT` | string | Yes | The full text of the `## Closure Checks` item being evaluated. |
| `ITEM_SOURCE_TICKET_ID` | string | Yes | The ticket ID from which the Closure Checks item was read. |
| `CLOSURE_TIMESTAMP` | string | Yes | ISO-8601 timestamp of the current verification run (e.g., `2026-05-19T13:00:00Z`). |

---

### Canonical parsing prefix

Hook output is identified by JSON structure on stdout. Parsers MUST verify that hook stdout is valid JSON containing all required fields (`valid`, `reason`, `severity`) before trusting the verdict. Non-JSON stdout or missing required fields MUST be treated as `{valid: false, severity: "block", reason: "Hook failed or returned non-JSON output"}`. The `contract_version` field in this doc is the authoritative schema version — hooks not conforming to the current contract_version MAY be rejected by the completion-verifier.

---

## Output Schema

Each hook must write a JSON object to stdout with the following fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `valid` | bool | Yes | `true` if the closure check item is satisfied, `false` otherwise. |
| `reason` | string | Yes | Human-readable explanation of the verdict. Used in the verifier output narrative. |
| `severity` | string | Yes | Impact of a `valid: false` result. One of: `"block"` (prevents closure) or `"warn"` (advisory, does not block). |

**Example output:**

```json
{
  "valid": false,
  "reason": "Accessibility audit score 72 — below the required 80 threshold for this epic.",
  "severity": "block"
}
```

**Default validator behavior**: When no hooks are registered (key absent), the verifier uses the built-in default — returns `{valid: true, severity: "warn"}` on present and well-formed items (permissive default for legacy compatibility).

---

## Closure Checks Integration

Items in the `## Closure Checks` section of a ticket are treated as end-state acceptance criteria. The completion-verifier reads this section in Step 2.5, separately from `## Success Criteria`, and evaluates each Closure Check item using the registered hooks in Step 3.5.

**Backward compatibility guarantee**: Tickets lacking a `## Closure Checks` section are treated as having an empty section — the step passes trivially. This ensures no regressions for tickets created before this mechanism.

---

## Worked Example

### Ticket body excerpt

```markdown
## Closure Checks

- [ ] Accessibility audit score ≥ 80 (automated via axe-core)
- [ ] Performance budget: LCP ≤ 2.5s on mobile (measured in CI)
```

### Hook: `accessibility-check`

Invoked by the completion-verifier with `ITEM_TEXT="Accessibility audit score ≥ 80 (automated via axe-core)"` as an environment variable.

Hook script runs the axe-core audit and produces:

```json
{
  "valid": true,
  "reason": "axe-core audit score: 94 — meets threshold of 80.",
  "severity": "warn"
}
```

### Hook: `performance-budget`

Invoked with `ITEM_TEXT="Performance budget: LCP ≤ 2.5s on mobile (measured in CI)"` as an environment variable.

```json
{
  "valid": false,
  "reason": "LCP measured at 3.1s on mobile — exceeds 2.5s budget.",
  "severity": "block"
}
```

The completion-verifier includes both results in `criteria_results` and sets `P1: FAIL` because one `severity: block` result is present.

---

## Versioning Policy

### Version 1 (current)

**contract_version: 1** is the initial release. This version defines the pluggable hook interface for `## Closure Checks` item evaluation.

**RETIRE policy**: contract_version v1 may only be retired via a formal version bump to v2 with a documented migration plan. v1 persists for backward compatibility until all consumers have migrated. The RETIRE owner must document the migration path in a v2 contract doc before decommissioning v1 hooks.

**Migration trigger for v2**: any breaking change to the input schema (new required fields), output schema (new required fields or changed `severity` enum values), or invocation convention.

---

## Backward Compatibility

- Tickets without a `## Closure Checks` section pass Step 3.5 trivially — the empty section produces no items to evaluate.
- When `project_closure_hooks` is absent from `dso-config.conf`, the completion-verifier runs the default SC9/SC13/SC14 gates (existing behavior, unchanged).
- Hooks returning non-JSON or exiting non-zero are treated as `{valid: false, severity: "block"}` with `reason: "Hook failed or returned non-JSON output"`.

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `dso:completion-verifier` | Parser | Reads `project_closure_hooks` key; dispatches hooks against `## Closure Checks` items in Step 3.5. |
| Host project hook scripts | Emitter | Registered via `project_closure_hooks`; must conform to input/output schema above. |

---

## Change Log

- **2026-05-19**: Initial version — defines pluggable hook interface, input/output schema, `project_closure_hooks` config key, Closure Checks integration, backward-compat guarantee, and versioning policy.
