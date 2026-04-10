---
name: verification-before-completion
description: Use when about to claim work is complete, fixed, or passing, before committing or creating PRs - requires running verification commands and confirming output before making any success claims; evidence before assertions always
allowed-tools:
---

# Verification Before Completion

**No completion claims without fresh verification evidence.**

## The Gate Function

```
BEFORE claiming any status or expressing satisfaction:

1. IDENTIFY: What command proves this claim?
2. RUN: Execute the FULL command (fresh, complete)
3. READ: Full output, check exit code, count failures
4. VERIFY: Does output confirm the claim?
   - If NO: State actual status with evidence
   - If YES: State claim WITH evidence
5. ONLY THEN: Make the claim
```

## Verification Commands

| Claim | Requires | Not Sufficient |
|-------|----------|----------------|
| Tests pass | `validate.sh --ci` or targeted `poetry run pytest path/test.py::test_name` | Previous run, "should pass" |
| Linter clean | `make lint-ruff` output: 0 errors | Partial check, extrapolation |
| Type checks pass | `make lint-mypy` output: no errors | Linter passing |
| Bug fixed | Test original symptom: passes | Code changed, assumed fixed |
| Regression test works | Red-green cycle verified | Test passes once |
| Agent completed | VCS diff shows changes | Agent reports "success" |
| CI passing | `ci-status.sh --wait` returns success | Last run was green |

## Red Flags — STOP if you catch yourself:

- Using "should", "probably", "seems to"
- Expressing satisfaction before verification
- About to commit/push/PR without verification
- Trusting agent success reports without independent check
- Thinking "just this once" or "I'm confident"
