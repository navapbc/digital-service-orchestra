# Contract: fp-recovery-ledger-schema

## Purpose

Schema `fp-recovery-ledger/v1` — a durable, append-only record of LLM-review false
positives that were overridden via `/dso:fp-recovery`. Written by
`scripts/ci/fp-recovery-ledger-write.sh` at clearance (FP-RECOVERY-WORKFLOW.md
Step 4.5). Created because the 2026-06-08 FP-analysis of ~48 override PRs had to
reverse-engineer FP root causes from scattered, sometimes unrecoverable PR
comments — there was no structured, queryable trail.

## Location

- Default: `<repo-root>/docs/audits/fp-recovery-ledger.jsonl` (project-local; outside
  the plugin tree per the no-dev-artifacts invariant). Override with `DSO_FP_LEDGER_PATH`.
- Format: **JSONL** — one JSON object per line, append-only. New records are appended;
  existing lines are never mutated.
- Pure reporting. The ledger is **not** on the bypass-propagation path (that is the
  ADR-0022 identity-based exemption), so it carries **no signature/HMAC** and is not
  load-bearing for any merge gate.

## Record fields

| Field | Type | Notes |
|-------|------|-------|
| `schema` | string | `"fp-recovery-ledger/v1"` |
| `pr` | int \| string | PR number (int when numeric) |
| `recorded_at` | string | UTC `YYYY-MM-DDTHH:MM:SSZ` |
| `verdict` | string | `"cleared"` (the FP was overridden) |
| `fp_category` | string | Root-cause taxonomy code (see below) — **validated**; write fails on an unknown value |
| `fp_rationale` | string | One-sentence human justification (same text as the Step 5b annotation) |
| `original_finding.severity` | string | `critical` \| `important` \| `fragile` \| `unknown` |
| `original_finding.class` | string | reviewer dimension: `verification` \| `correctness` \| `security` \| `design` \| `maintainability` \| `performance` \| `unknown` |
| `original_finding.location` | string | `<file>:<line>` of the blocking finding (may be empty) |
| `original_finding.summary` | string | ≤30-word summary of what the finding claimed (**required**) |
| `original_finding.fingerprint` | string | sha256 (16 hex) of `location` (or `summary` when no location) — content-stable, pr-free; mirrors `review-finding-identity.sh` cited-lines identity |
| `neutral_reviewer_hash` | string | `REVIEWER_HASH` of the neutral opus re-review that cleared the PR (may be empty) |
| `cleared_by` | string | GitHub login of the bypass actor who merged (may be empty) |

Required at write time: `pr`, `fp_category`, `fp_rationale`, `original_finding.summary`.

## FP root-cause taxonomy (`fp_category`)

From the 2026-06-08 FP-analysis. Use the best-fit; use `TX` only when none fit.

| Code | Meaning |
|------|---------|
| `T1` | type/variable/logic-claim error — refutable by reading the code |
| `T2` | missing-file-or-symbol that actually exists (often elsewhere) |
| `T3` | speculative reachability / security / fail-open with no real sink |
| `T4` | stale context — re-flags already-fixed or prior-cycle code |
| `T5` | behavioral-testing-standard misapplication (post-condition test called weak; Rule-5 structural greps on `.md` called source-file-grepping; demands implementation-coupled tests) |
| `T6` | test-quality misflag — wrong change-detector / tautology / mock-divergence call |
| `T7` | missing cross-file context (correct given a file not in the diff) |
| `T8` | idiom / convention misread (intentional shell/language idiom flagged) |
| `T9` | scope-misattribution — flags code not in the diff |
| `T10` | severity-inflation — real nit mis-scored critical/important |
| `TX` | other (describe in `fp_rationale`) |

## Example

```json
{"schema":"fp-recovery-ledger/v1","pr":712,"recorded_at":"2026-06-08T01:30:00Z","verdict":"cleared","fp_category":"T5","fp_rationale":"RETURN trap is the sole lockdir cleanup path; the observable post-condition assertion IS the contract","original_finding":{"severity":"critical","class":"verification","location":"tests/scripts/test-merge-to-main-spent-classifier.sh:406","summary":"existence-only assertion would pass even if the trap were removed","fingerprint":"a1b2c3d4e5f60718"},"neutral_reviewer_hash":"d9392797","cleared_by":"JoeOakhartNava"}
```

## Consuming the ledger

```bash
# FP rate by category
jq -r '.fp_category' docs/audits/fp-recovery-ledger.jsonl | sort | uniq -c | sort -rn
# Recurring findings (same fingerprint overridden more than once)
jq -r '.original_finding.fingerprint' docs/audits/fp-recovery-ledger.jsonl | sort | uniq -d
```
