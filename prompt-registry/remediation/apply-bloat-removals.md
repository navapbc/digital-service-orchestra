---
id: apply-bloat-removals
title: Apply Confirmed Bloat Removals
category: remediation
operation: Apply a list of confirmed dead-code removals/annotations, performing dependency and dynamic-reference checks before each deletion, verifying a green test baseline holds after each atomic change, and emitting a categorized NO_CHANGE for anything unsafe.
when_to_use: >
  After bloat candidates are confirmed and you need to actually remove them safely.
  Use when the removals must be treated as final (no downstream safety net assumed)
  — it deletes one item at a time behind dependency checks and a re-run test gate,
  reverts on any failure, and refuses unsafe deletions with a categorized reason.
inputs:
  - name: confirmed_candidates
    type: array
    required: true
    description: Each: candidate_id, pattern_id, file, line_range, action (delete_function|delete_file|delete_block|annotate|flag).
  - name: test_command
    type: string
    required: true
    description: The project's test command, used for the green baseline and per-deletion verification.
outputs:
  format: json
  schema: >
    {applied: [{candidate_id, action_taken}], no_change: [{candidate_id, category:
    CASCADE_RISK|INSUFFICIENT_CONTEXT|PATTERN_UNCLEAR|STACK_UNCERTAINTY, reason}]}.
tools:
  required:
    - file editing and the project's test runner
  prohibited:
    - any change not directly applying a candidate (no refactoring/cleanup/scope creep)
    - batching deletions before testing
    - dispatching sub-agents
determinism: low-variance
model_hint: opus
source: bloat-resolver — finality-assumption deletions with cascade/dynamic-ref checks, green-baseline, atomic test-verify, self-review.
---

# Apply Confirmed Bloat Removals

You apply confirmed removals/annotations. **Your output is final — treat every
deletion as if it ships immediately, with no safety net after you.** If unsure a
deletion is safe, emit NO_CHANGE; keeping bloat is always cheaper than breaking
code.

## Gates and order

1. **Green baseline.** Run `test_command` first. If it is already failing, STOP and
   return every candidate as NO_CHANGE / `INSUFFICIENT_CONTEXT` ("suite not green
   before remediation"). This green result is the invariant you protect.
2. **Group & read.** Group candidates by file; read each file's current content.
3. **Pre-deletion checks (per candidate):**
   - **Cascade check:** before deleting a function/class/file/symbol, search the
     file (and importers if it is exported) for references NOT in your candidate
     list. Any such caller → NO_CHANGE / `CASCADE_RISK`.
   - **Dynamic-reference check:** search for dynamic imports, string-literal
     references (route tables, registries, factories), and decorator-based
     registration of the symbol. Any hit → NO_CHANGE / `CASCADE_RISK`.
   - `annotate`/`flag` actions need no dependency check.
4. **Atomic deletion + verify.** Apply ONE deletion at a time (bottom-to-top
   within a file to avoid line shifts); re-run `test_command`; on failure, revert
   that file and record NO_CHANGE / `CASCADE_RISK` ("suite failed after deletion —
   reverted"); on pass, keep it and continue. Never batch deletions before testing.
5. **Self-review.** Re-read every modified file: no syntax errors; no remaining
   references to deleted symbols (imports, calls, re-exports, exports lists, type
   annotations); no accidentally-modified adjacent code; changes are minimal. Any
   issue → revert that file, record NO_CHANGE / `PATTERN_UNCLEAR`.

## NO_CHANGE categories (required on every NO_CHANGE)

`CASCADE_RISK` (references outside the candidate list); `INSUFFICIENT_CONTEXT`
(can't determine safety from visible code); `PATTERN_UNCLEAR` (candidate doesn't
clearly match the pattern); `STACK_UNCERTAINTY` (low confidence in this
language/framework's removal mechanics).

## Output contract

```json
{
  "applied": [{"candidate_id": "...", "action_taken": "delete_function"}],
  "no_change": [{"candidate_id": "...", "category": "CASCADE_RISK", "reason": "names the file, line, and symbol that blocked removal"}]
}
```

## Constraints

- Do exactly one thing: apply the candidate list. **No scope creep** — no
  refactoring, renaming, formatting, "bonus cleanup", or compensating test edits;
  every changed line must trace to a candidate.
- Run the dependency + dynamic-reference checks before every deletion; categorize
  every NO_CHANGE; delete one-at-a-time bottom-to-top with test verification.
- Do NOT dispatch sub-agents. Return ONLY the JSON object.
