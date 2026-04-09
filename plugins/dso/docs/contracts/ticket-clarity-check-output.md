# Contract: ticket-clarity-check.sh Output Interface

- Signal Name: CLARITY_SCORE
- Status: accepted
- Scope: sprint Phase 1 clarity gate (epic 0d66-ceb6)
- Date: 2026-04-06

## Purpose

This document defines the output interface between `ticket-clarity-check.sh` (emitter) and the `/dso:sprint` Phase 1 clarity gate (parser). The emitter evaluates a ticket's clarity — presence and quality of description, acceptance criteria, file impact, and success indicators — then prints a single JSON object to stdout and exits with a code indicating pass or fail. The parser uses the `verdict` field to determine whether the sprint may proceed or must pause for ticket enrichment.

This contract must be agreed upon before implementation begins to prevent implicit assumptions and ensure the emitter and parser stay in sync.

---

## Signal Name

`CLARITY_SCORE`

---

## Emitter

`plugins/dso/scripts/ticket-clarity-check.sh` # shim-exempt: internal implementation path reference

The emitter evaluates the ticket identified by its argument (or reads JSON ticket data from stdin when `--stdin` is passed), computes a clarity score, and prints a single JSON object to stdout. It exits `0` when the score meets the threshold (pass) and `1` when below threshold (fail). It exits `2` on error or invalid input.

**Testing mode**: When invoked with `--stdin`, the emitter reads a JSON ticket object from stdin instead of calling the ticket CLI. This allows unit tests to inject fixture data without a live ticket system.

---

## Parser

`plugins/dso/skills/sprint/SKILL.md` — Phase 1 clarity gate # shim-exempt: internal implementation path reference

The parser invokes the emitter with the current epic ticket ID, reads the JSON from stdout, and inspects the `verdict` field. When `verdict` is `"fail"`, the sprint must not proceed to Phase 2 until the ticket owner enriches the ticket and the emitter re-evaluates to `"pass"`.

---

## Fields

The emitter outputs a single JSON object on stdout. All fields are required.

| Field | Type | Description |
|---|---|---|
| `score` | integer | Aggregate clarity score across all evaluated dimensions. Higher is better. Range depends on the scoring rubric but is always non-negative. |
| `verdict` | string (enum) | `"pass"` when `score >= threshold`; `"fail"` when `score < threshold`. This is the primary routing signal. |
| `threshold` | integer | The minimum score required for a passing verdict. Emitted alongside `score` so the parser can surface both to the user for diagnostic output. |

### `verdict` Enum Values

| Value | Meaning |
|---|---|
| `"pass"` | Score meets or exceeds the threshold. The sprint clarity gate is satisfied and Phase 2 may proceed. |
| `"fail"` | Score is below the threshold. The sprint must pause and surface the gap to the user before continuing. |

### Canonical parsing prefix

The parser MUST match against:

- `CLARITY_SCORE` — this contract defines a JSON stdout interface. The parser reads the full JSON object from the emitter's stdout and inspects the `verdict` field. No line-prefix matching applies; the parser must deserialize the JSON object and check `verdict` against `"pass"` or `"fail"` to determine routing.

---

## Exit Codes

| Exit code | Meaning |
|---|---|
| `0` | Pass — `score >= threshold`; stdout contains valid JSON with `verdict: "pass"` |
| `1` | Fail — `score < threshold`; stdout contains valid JSON with `verdict: "fail"` |
| `2` | Error — invalid input (missing ticket ID, unreadable stdin, malformed ticket JSON); stdout may be absent or partial |

---

## Example Output

### Passing ticket

```json
{"score": 8, "verdict": "pass", "threshold": 5}
```

### Failing ticket

```json
{"score": 3, "verdict": "fail", "threshold": 5}
```

---

## Failure Contract

Exit code `2` (error/absent) and structural errors are handled as distinct cases:

### Exit 2 (error or absent script) — fail-open

If the emitter:

- is absent (script file not found), or
- exits with code `2` (error/invalid-input),

then the parser **must** fall through to Layer 2 (Scope Certainty Assessment) rather than routing to Layer 3. The script being unavailable or erroring is not evidence that the ticket is unclear — it is evidence that structural evaluation is not possible. The parser emits a warning (`"ticket-clarity-check.sh unavailable — falling through to Layer 2"`) so that silent degradation is detectable.

### Timeout or malformed output — pessimistic (treat as fail)

If the emitter:

- times out (exit code 144 from `test-batched.sh` or SIGURG),
- or outputs malformed JSON (not parseable or missing required fields),

then the parser **must** treat the result as `verdict: "fail"` with `score: 0` and route to Layer 3 (User Escalation). Timeouts and malformed output indicate a dysfunctional emitter, not a merely absent one, and warrant user visibility.

The parser must emit a warning to the user in all non-zero cases so that silent degradation is detectable.

---

## Testing Mode (`--stdin`)

When invoked with `--stdin`, the emitter reads a JSON ticket object from stdin rather than calling the ticket CLI. The JSON object must conform to the ticket event format (see `plugins/dso/docs/contracts/ticket-event-format.md`). This mode is used by unit tests to inject fixture data without a live ticket system. Exit code semantics are identical to normal mode.

Example invocation:

```bash
echo '{"ticket_id":"0000-test","description":"...","acceptance_criteria":"..."}' \
  | plugins/dso/scripts/ticket-clarity-check.sh --stdin  # shim-exempt: contract example showing raw script interface
```

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `plugins/dso/scripts/ticket-clarity-check.sh` | Emitter | Evaluates ticket clarity and emits JSON + exit code # shim-exempt: internal implementation path reference |
| `plugins/dso/skills/sprint/SKILL.md` Phase 1 | Parser | Invokes emitter; blocks sprint progression on `verdict: "fail"` # shim-exempt: internal implementation path reference |

All implementors must read this contract before modifying the emitter script or Phase 1 parser logic. Changes to the signal format require updating both the emitter and parser and this document atomically in the same commit.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal, exit code semantic changes) require updating both the emitter and this document atomically in the same commit. Additive changes (new optional fields) are backward-compatible for parsers that ignore unknown keys and do not require a version bump.

### Change Log

- **2026-04-06**: Initial version — defines CLARITY_SCORE output interface for `ticket-clarity-check.sh` → sprint Phase 1 clarity gate. Establishes JSON schema, exit code semantics, `--stdin` testing mode, and fail-safe default for absent/erroring emitter.
