# Contract: ack-rationale-rubric

## Purpose

This rubric governs the `--if-skipped` rationale string required when acknowledging a PRECONDITIONS graceful-degradation entry via:

```
.claude/scripts/dso preconditions-ack <story_id> <decision_id> --if-skipped "<rationale>"
```

A substantive rationale helps auditors understand *why* a gate degradation was accepted. Terse or reflexive strings (e.g., "skipping this") provide no signal and will fail automated checks.

Cross-reference: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/preconditions-schema-v2.md` (decision record schema), `${CLAUDE_PLUGIN_ROOT}/scripts/check-unacked-degradations.sh`. # shim-exempt: doc cross-reference

---

## Automated Validation Rules

### 1. Minimum Length

After trimming leading/trailing whitespace, the rationale must be **>=10 characters**.

### 2. 3-word-window Requirement

At least **3 consecutive normalized words** from `precondition_text` (the original gate condition string stored in the decision record) must appear verbatim in the normalized rationale.

Normalization: lowercase, collapse runs of whitespace and punctuation to single space, strip leading/trailing whitespace.

This requirement ensures the rationale specifically addresses the gate that was degraded rather than being copy-pasted boilerplate.

### 3. Non-Latin Script Fallback

If the rationale contains primarily non-Latin characters (heuristic: >=50% of word characters are outside ASCII range U+0000–U+007F), the 3-word-window check is bypassed and the record is flagged `rationale_script: non-latin`. Such records are **excluded from automated pass/fail scoring** and require a human reviewer to assess substantiveness during the next audit cycle.

### 4. if_skipped Field Storage

The validated rationale string is stored verbatim in the decision record's `if_skipped` field. Downstream audit scripts read this field to assess coverage. An empty or missing `if_skipped` field means the degradation was acknowledged without a rationale — those records count as FAIL in audit scoring.

---

## PASS Examples

The following rationales satisfy all automated checks (assuming the gate's `precondition_text` overlaps):

- `"implementation-plan gate was degraded because the story had no parent epic; manually verified no sibling stories existed"`
- `"review gate degraded in worktree session that had already undergone review on main branch"`
- `"test-gate degraded: story only modifies documentation files with no executable logic; behavioral tests are not applicable"`
- `"implementation-plan gate skipped: this task was created as a hotfix with direct user instruction and no planning phase was required"`

---

## FAIL Examples

The following rationales fail one or more rules:

| Rationale | Failure reason |
|-----------|----------------|
| `"skipping this"` | Length < 10 chars after trim; no gate-word overlap |
| `"not needed"` | No 3-word overlap with gate condition text |
| `"acknowledged"` | Single word; no gate-word overlap |
| `"ok"` | Length < 10 chars |
| `"yes"` | Length < 10 chars; single word |

---

## Sample-ack Rubric

`--sample-ack` allows a single rationale to acknowledge an entire **class** of degradations when there are >=4 entries of the same class in one story. The same length and 3-word-window rules apply to each of the 3 rationale strings sampled during audit.

Rules:
- All **3 sampled rationales must independently pass** length and 3-word-window checks.
- If any sampled rationale fails, the entire sample-ack is considered FAIL and each entry must be acknowledged individually.
- The `class` value must match a recognized gate class name stored in the decision record (e.g., `implementation-plan`, `review`, `test-gate`).

---

## Audit Expectations

A random sample of 20 `--if-skipped` rationale events is drawn per audit cycle.

**>=80% of sampled events** must have substantive rationales (PASS per the rules above).

Events with `rationale_script: non-latin` are excluded from the denominator of the 80% calculation.

Audit results are surfaced in the retro report. Audit failure at the repo level triggers a CLAUDE.md note recommending stricter human review of degradation acknowledgments for the next sprint cycle.
