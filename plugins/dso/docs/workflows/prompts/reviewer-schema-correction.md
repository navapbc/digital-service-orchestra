# Reviewer Schema Correction Prompt Fragment

This prompt fragment is injected during correction dispatch when a reviewer's findings fail
schema validation. Its sole purpose is to repair schema-level field violations in an existing
set of findings — it does NOT re-review the diff or re-evaluate code quality.

---

## SAFEGUARD 1 — Schema-Only Scope Preamble

**READ THIS BEFORE TAKING ANY ACTION.**

You are performing a **schema correction only**. Your task is strictly limited to fixing
fields in the findings JSON so they pass schema validation.

You MUST NOT:

- Add new findings
- Remove existing findings
- Change any finding's severity
- Re-evaluate the diff or reassess code quality
- Alter any finding's description or category
- Change scores or summary assessments

The findings below were produced by a code reviewer agent. That agent's judgments are
final. Your only job is to correct field-level schema violations so the JSON passes
validation. Any change beyond schema compliance is a correction failure.

---

## SAFEGUARD 2 — Frozen Field Enumeration

The following fields are **frozen**: they MUST be byte-for-byte identical to the
original finding. Do NOT modify them under any circumstance — not for formatting,
not for clarity, not to fix perceived errors in their content.

| Field | Frozen |
|---|---|
| `severity` | YES — byte-for-byte identical to original |
| `category` | YES — byte-for-byte identical to original |
| `description` | YES — byte-for-byte identical to original |
| `file` | YES — byte-for-byte identical to original |
| `cited_lines` | YES — byte-for-byte identical to original |
| `finding_id` | YES — byte-for-byte identical to original (see exception below) |

**`finding_id` exception**: If `finding_id` is absent, empty, or structurally malformed
(not matching `f-<hex8>` format), you MAY generate a valid `finding_id` in the format
`f-<8 lowercase hex characters>` (e.g., `f-a1b2c3d4`). You MUST NOT change a
`finding_id` that is already present and structurally valid.

Any change to a frozen field that is not explicitly permitted above is a correction
failure — revert the change and leave the field as-is.

---

## SAFEGUARD 3 — Explicit Read-Then-Copy for `cited_excerpt` with `__UNREADABLE__` Sentinel

The `cited_excerpt` field must contain **verbatim code** from the source file at the
cited line range. This field is correctable (see Correctable Fields below).

**Procedure for `cited_excerpt`**:

1. Identify the `file` and `cited_lines` for the finding.
2. Use the Read tool to open the actual source file at the cited line range.
3. Copy the exact text verbatim from the file into `cited_excerpt`.

**If the code cannot be read** — because the file is not present in the diff, the line
range is invalid, the file does not exist, or the content is otherwise unreadable — write
exactly the sentinel value:

```text
__UNREADABLE__
```

Do NOT paraphrase, summarize, or fabricate code. Do NOT infer what the code might say.
Do NOT copy text from memory or from the diff description. If you cannot read the actual
bytes at the cited location, the only valid value is `__UNREADABLE__`.

Hallucinating an excerpt is worse than writing `__UNREADABLE__` — a hallucinated excerpt
silently embeds false information in the review record and can mislead future reviewers.

---

## Correctable Fields

Only these fields may be modified during schema correction:

| Field | Correction Rule |
|---|---|
| `cited_excerpt` | Read the actual source file at the cited line range and paste verbatim. Write `__UNREADABLE__` if the file cannot be read. |
| `reachability` | May be added if absent and required by schema (severity `critical`, `important`, or `fragile`). Do NOT alter existing `reachability` content — add only if missing. (Note: this constraint is enforced by prompt instruction, not by code; the correction dispatcher does not validate reachability changes.) |
| `finding_id` | May be generated ONLY if absent, empty, or malformed. See Frozen Field `finding_id` exception above. |

All other fields are frozen. Do not touch them.

---

## Expected Output Format

Return the corrected findings in the same JSON structure as the original. The top-level
structure must be preserved exactly:

```json
{
  "findings": [
    {
      "severity": "<unchanged>",
      "category": "<unchanged>",
      "description": "<unchanged>",
      "file": "<unchanged>",
      "cited_lines": ["<unchanged>"],
      "finding_id": "<unchanged or newly generated if malformed>",
      "cited_excerpt": "<verbatim code from file, or __UNREADABLE__>",
      "reachability": "<unchanged, or added if absent and required>"
    }
  ],
  "summary": "Schema correction applied: <brief description of what was fixed>"
}
```

Do not add, remove, or reorder top-level keys. Do not add keys not present in the
original. The corrected JSON must be structurally identical to the original except
for the correctable fields listed above.

---

## Correction Failure Conditions

The following outcomes constitute a correction failure. If you encounter them, stop
and report the specific failure rather than proceeding:

- Any frozen field was changed
- A finding was added or removed
- `cited_excerpt` was written with fabricated content instead of `__UNREADABLE__`
- `finding_id` was changed when the original was already structurally valid
- The output JSON has a different structure than the original
