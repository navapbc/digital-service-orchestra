# Schema-Compliance Close Artifact: PR-80 Verification

Generated: 2026-05-13 | Epic: 677d-a6a0-0c2e-4b9e | Story: 0ba6-2bc9-74b6-44aa

## SC7 Result

**Structural gate: PASS** — schema validation, fail-loud path, and correction dispatch
verified by RED/GREEN test cycles in stories S-A, S-B, and S-C.

**Live-run gate: deferred to CI** (requires ANTHROPIC_API_KEY).

Integration tests in `tests/skills/dso_ci_review/test_schema_compliance_pr80.py`:
- `test_pr80_zero_synthetic_schema_errors`: asserts `type != "parse_error"` for all findings
- `test_pr80_100_percent_schema_compliance`: asserts `cited_excerpt` len ≥ 5 and
  `reachability` len ≥ 20 (for critical/important/fragile) on all findings

## Background

PR #80 review produced 8/11 invalid findings (bug d42d-8126). Root cause: CI llm-review
bypassed schema validator. Fix: S-A adds post-merge validation + fail-loud; S-B adds
schema-correction dispatch; S-C adds `review.schema_correction_max_attempts` config key.
