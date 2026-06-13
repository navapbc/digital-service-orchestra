---
id: apply-fix-across-occurrences
title: Apply a Reference Fix Across Confirmed Occurrences
category: remediation
operation: Given a confirmed pattern, a reference fix, and a batch of files containing its occurrences, apply the same fix to every occurrence test-first (RED→GREEN), returning a batch completion record.
when_to_use: >
  When one root-cause pattern recurs in many places and you want to remediate them
  uniformly, not bespoke per site — e.g. after a scan located all occurrences of an
  anti-pattern. Use to apply a known reference fix consistently across an assigned
  file batch, each change guarded by a failing-then-passing test.
inputs:
  - name: pattern
    type: string
    required: true
    description: The confirmed pattern being fixed and why it is wrong.
  - name: reference_fix
    type: string
    required: true
    description: The fix already applied to the original occurrence — the template to replicate.
  - name: occurrences
    type: array
    required: true
    description: The confirmed occurrence sites (file + line) within the assigned files to fix.
outputs:
  format: structured-block
  schema: >
    A batch completion record: per file, the occurrences fixed, the test
    written/updated per site (or no_test_file), and RED→GREEN confirmation; plus a
    rollup of fixed/skipped counts.
tools:
  required:
    - file editing and the project's test runner
  optional: []
  prohibited:
    - inventing a different fix approach than the reference fix without cause
    - altering unrelated logic
    - dispatching nested sub-agents
determinism: low-variance
model_hint: sonnet
source: Anti-pattern batch fixer — uniform reference-fix application across occurrences with RED→GREEN per site.
---

# Apply a Reference Fix Across Confirmed Occurrences

You apply one confirmed reference fix to every assigned occurrence of a pattern,
using RED→GREEN discipline per site. You handle one batch of files in a single
pass.

## Procedure (per assigned file)

1. **Confirm each occurrence.** Read each site with surrounding context; verify
   the pattern is actually present (same construct and semantics, not a
   look-alike). Skip and record any that are not genuine.
2. **Write a RED test.** Before editing the source, add a test that exercises the
   affected path and fails because the pattern is present; run it to confirm RED.
   If multiple occurrences share a file, one test may cover them (or separate
   tests for distinct paths). If no test file exists for the source, record
   `no_test_file` and proceed without a RED test.
3. **Apply the fix.** Make the minimal change that resolves the pattern, following
   the **reference fix** — do not invent a different approach unless the site
   genuinely requires it. Do not alter unrelated logic.
4. **Confirm GREEN.** Re-run the test; confirm it passes.

## Output contract

Return a batch completion record:

```
BATCH_RESULT:
  files:
    - file: <path>
      occurrences_fixed: <n>
      occurrences_skipped: <n with one-line reason>
      test: <test name added/updated, or "no_test_file">
      red_confirmed: true|false
      green_confirmed: true|false
  totals: fixed=<n> skipped=<n> files=<n>
```

## Constraints

- Do exactly one thing: apply the reference fix across the assigned occurrences.
- Replicate the reference fix; do not invent a divergent approach without cause,
  and do not touch unrelated logic.
- Write the RED test before the source edit for each site that has a test file.
- Do NOT dispatch nested sub-agents.
