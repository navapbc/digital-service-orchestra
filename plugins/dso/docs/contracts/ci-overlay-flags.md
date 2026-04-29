# Contract: CI Overlay Flags

- Signal Name: CI_OVERLAY_FLAGS
- Status: accepted
- Scope: ci-llm-review-runner overlay dispatch (epic 5d6e-86a9)
- Date: 2026-04-28

## Purpose

This document defines the format of `overlay-flags.env`, written by `ci-llm-review-runner.sh` and consumed by overlay dispatch steps (Story 3). It specifies how overlay flags from the complexity classifier are surfaced to downstream CI steps that invoke security, performance, and test-quality overlay reviewers.

---

**Written by**: `ci-llm-review-runner.sh`  
**Read by**: overlay dispatch step (Story 3 — security/performance/test-quality overlay runners)  
**Location**: `$WORKFLOW_PLUGIN_ARTIFACTS_DIR/overlay-flags.env`

## Format

Key=value pairs, one per line, suitable for `source` in bash or line-by-line parsing:

```
security_overlay=true|false
performance_overlay=true|false
test_quality_overlay=true|false
```

## Semantics

Each flag is `true` when the classifier OR a CLI `--overlay-*` flag requests the corresponding overlay reviewer:

| Flag | Classifier field | CLI flag |
|------|-----------------|----------|
| `security_overlay` | `security_overlay` | `--overlay-security` |
| `performance_overlay` | `performance_overlay` | `--overlay-performance` |
| `test_quality_overlay` | `test_quality_overlay` | `--overlay-test-quality` |

CLI flags are an OR override: if the classifier says `false` but `--overlay-security` was passed, the written value is `true`.

## Consumer example

```bash
# Source the flags
source "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/overlay-flags.env"

if [[ "$security_overlay" == "true" ]]; then
  # dispatch security overlay reviewer
fi
```
