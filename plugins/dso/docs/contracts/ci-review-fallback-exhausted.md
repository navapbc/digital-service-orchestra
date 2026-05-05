# Contract: fallback_exhausted Signal

- Signal Name: fallback_exhausted
- Status: accepted
- Scope: ci-llm-review-runner.sh → orchestrator fallback path (DD3)
- Date: 2026-05-05

## Purpose

This document defines the output schema for the `fallback_exhausted` signal emitted by `ci-llm-review-runner.sh` when all fallback strategies for a review agent have been attempted and none succeeded. When the primary model fails and all cross-provider and context-reduction fallbacks are exhausted, the runner emits this signal to the orchestrator so that partial findings are preserved and the failure is surfaced for human review rather than silently discarded.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the emitter and parser stay in sync.

---

## Signal Name

`fallback_exhausted`

---

## Emitter

`ci-llm-review-runner.sh` — emits this signal when:

1. The primary model for a review agent returns a terminal error, AND
2. All entries in `attempted_cross_provider[]` have been tried and failed, AND
3. All entries in `attempted_context_models[]` have been tried and failed.

The signal is written atomically to a JSON file in `$WORKFLOW_PLUGIN_ARTIFACTS_DIR/` (see Atomic Write Note below).

---

## Parser

`ci-llm-review-runner.sh` orchestrator fallback handler — reads the signal file after all fallback attempts are exhausted to determine whether to surface a partial-findings artifact or halt the run.

---

## Signal Format

```json
{
  "signal": "fallback_exhausted",
  "agent_id": "dso:code-reviewer-standard",
  "primary_model": "claude-sonnet-4-6",
  "attempted_cross_provider": [
    "openai:gpt-4o",
    "anthropic:claude-haiku-4-5"
  ],
  "attempted_context_models": [
    "claude-sonnet-4-6[short]",
    "claude-haiku-4-5[short]"
  ],
  "final_exception_class": "OverloadedError",
  "final_exception_message": "Service overloaded, please retry after 30 seconds"
}
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `signal` | string | Yes | Always `"fallback_exhausted"`. Identifies the signal type for parsers. |
| `agent_id` | string | Yes | The identifier of the review agent that exhausted all fallbacks (e.g., `"dso:code-reviewer-standard"`). |
| `primary_model` | string | Yes | The model ID that was attempted first before fallback was triggered (e.g., `"claude-sonnet-4-6"`). |
| `attempted_cross_provider` | array of strings | Yes | Ordered list of cross-provider model IDs attempted as fallbacks. Empty array `[]` if no cross-provider fallbacks were configured. Each entry is a `provider:model-id` string. |
| `attempted_context_models` | array of strings | Yes | Ordered list of context-reduction model IDs attempted as fallbacks. Empty array `[]` if no context-reduction fallbacks were configured. Each entry identifies the model and context window variant used. |
| `final_exception_class` | string | Yes | The exception class or error type from the last failed attempt (e.g., `"OverloadedError"`, `"RateLimitError"`, `"TimeoutError"`). |
| `final_exception_message` | string | Yes | The human-readable error message from the last failed attempt. Must not be empty. |

---

## Example Payload

**All fallbacks exhausted after cross-provider and context-reduction attempts:**

```json
{
  "signal": "fallback_exhausted",
  "agent_id": "dso:code-reviewer-deep-correctness",
  "primary_model": "claude-sonnet-4-6",
  "attempted_cross_provider": [
    "openai:gpt-4o",
    "openai:gpt-4o-mini"
  ],
  "attempted_context_models": [
    "claude-sonnet-4-6[32k]",
    "claude-haiku-4-5[32k]"
  ],
  "final_exception_class": "RateLimitError",
  "final_exception_message": "Rate limit exceeded for model claude-haiku-4-5 in 32k context mode: retry after 60s"
}
```

**No cross-provider fallbacks configured — context-reduction only:**

```json
{
  "signal": "fallback_exhausted",
  "agent_id": "dso:code-reviewer-light",
  "primary_model": "claude-haiku-4-5",
  "attempted_cross_provider": [],
  "attempted_context_models": [
    "claude-haiku-4-5[short]"
  ],
  "final_exception_class": "TimeoutError",
  "final_exception_message": "Request timed out after 120 seconds with no response"
}
```

---

## Atomic Write Note

The `fallback_exhausted` signal file MUST be written atomically. Writers must:

1. Write the full JSON payload to a temporary file in the same directory (e.g., `fallback_exhausted.json.tmp`).
2. Rename (via `mv`) the temp file to the final path (`fallback_exhausted.json`).

This prevents parsers from reading a partially-written file if the runner is interrupted mid-write. Parsers that observe a missing file (no signal) treat the fallback as still in progress; parsers that observe the final file treat it as a complete, readable signal.

---

## Partial-Findings Preservation Note

When `fallback_exhausted` is emitted, any partial findings collected before the terminal failure MUST be preserved. The runner writes a companion `partial-findings.json` to `$WORKFLOW_PLUGIN_ARTIFACTS_DIR/` alongside the `fallback_exhausted.json` signal. Partial findings contain whatever review output was accumulated before the exhausting failure (which may be an empty `findings` array if no output was collected). The orchestrator surfaces both artifacts to the human reviewer so that incomplete review results are visible rather than silently dropped.

---

### Canonical parsing prefix

The parser MUST match against the JSON key `"fallback_exhausted"` in the findings array. Each entry in the findings array with `"type": "fallback_exhausted"` represents one exhausted agent. Parsers MUST deserialize the JSON object and inspect the 6 required fields listed in the Field Definitions section above. No line-prefix matching applies — the parser reads the full JSON findings entry.

---

## Consumers

| Component | Role | Notes |
|-----------|------|-------|
| `ci-llm-review-runner.sh` | Emitter | Writes signal after all fallback strategies fail for a given agent |
| CI orchestrator fallback handler | Parser | Reads signal to surface failure and preserve partial findings |
| Human reviewer / CI summary | Consumer | Receives surfaced partial-findings artifact and fallback signal for manual triage |

All implementors must read this contract before modifying fallback logic in `ci-llm-review-runner.sh` or the orchestrator's fallback handler. Changes to the signal format require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Per-Agent File Ownership

When deep-tier dispatch runs 3 specialists (correctness, verification, hygiene) plus arch synthesis
in parallel, each agent writes to a distinct slot file to prevent parallel-write corruption:

| Agent | Slot file |
|-------|-----------|
| correctness specialist | `$WORKFLOW_PLUGIN_ARTIFACTS_DIR/reviewer-findings-correctness.json` |
| verification specialist | `$WORKFLOW_PLUGIN_ARTIFACTS_DIR/reviewer-findings-verification.json` |
| hygiene specialist | `$WORKFLOW_PLUGIN_ARTIFACTS_DIR/reviewer-findings-hygiene.json` |
| arch synthesis | `$WORKFLOW_PLUGIN_ARTIFACTS_DIR/reviewer-findings.json` (canonical output) |

The `fallback_exhausted` entry, when generated, is written into the canonical `reviewer-findings.json`
via the atomic write protocol (temp file + `os.replace()`). Concurrent partial results from
surviving specialists are preserved in their respective slot files and merged by the arch synthesis agent.

---

## Versioning

This contract is versioned. Breaking changes (format changes, field removal, type changes) require updating both all emitters and parsers and this document atomically in the same commit. Additive changes that do not affect existing field definitions are backward-compatible.

### Change Log

- **2026-05-05**: Initial version — defines `fallback_exhausted` signal for DD3 schema documentation. Establishes 6-field schema, atomic write requirement, and partial-findings preservation semantics.
