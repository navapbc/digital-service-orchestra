# CI Review Consumer List

**Purpose**: Pre-deletion consumer audit required before S3/e596 deletes `llm-api-call.sh` and reduces `ci-llm-review-runner.sh` to a shim. This document tracks every file that references either script, the type of reference, and its planned disposition.

**Generated**: 2026-05-05

---

## `llm-api-call.sh` Consumers

| File | Reference Type | Disposition |
|------|----------------|-------------|
| plugins/dso/scripts/ci-llm-review-runner.sh | functional (primary consumer — 10+ invocations) | Replaced by `python3 -m dso_ci_review.runner` in S3/e596 |
| plugins/dso/scripts/merge-to-main-pr.sh | functional (secondary, non-CI-review, 3 invocations via `_LLM_DISPATCH_CMD` env var) | Annotated as compat-shim in 4b97 task a554 |
| plugins/dso/docs/CONFIGURATION-REFERENCE.md | documentation "Used by" fields (8 entries) | Updated to `python3 -m dso_ci_review.runner` in 4b97 task bf50 |
| CLAUDE.md | documentation reference | Updated in S6/e71e |
| .claude/dso-config.conf | comment (line 221) | Updated in 4b97 task 724f |
| tests/scripts/test-ci-llm-review-runner.sh | test file for the runner (tests both scripts) | Updated/deleted in S3/e596 |
| tests/scripts/test-llm-api-call.sh | test file for the script itself | Deleted in S3/e596 |
| tests/scripts/test-claude-md-ci-review.sh | asserts CLAUDE.md references `llm-api-call.sh` | Updated in S6/e71e |
| tests/integration/test-merge-to-main-pr-thread-resolution.sh | creates test stub via `_LLM_DISPATCH_CMD` | No change needed (uses env var override) |
| .test-index | test mapping entry (line 70) | Updated in S3/e596 |

---

## `ci-llm-review-runner.sh` Consumers

| File | Reference Type | Disposition |
|------|----------------|-------------|
| .github/workflows/ci.yml | functional invocation (line 195): `gh pr diff "$PR_NUMBER" \| bash plugins/dso/scripts/ci-llm-review-runner.sh` | Updated to `python3 -m dso_ci_review.runner` in S3/e596 |
| plugins/dso/templates/ci-dso-staged.yml | template invocation (line 126): `bash "${{ vars.DSO_PLUGIN_PATH }}/scripts/ci-llm-review-runner.sh"` | Updated in S3/e596 |
| plugins/dso/docs/CONFIGURATION-REFERENCE.md | documentation (multiple entries) | Updated in 4b97 task bf50 |
| plugins/dso/docs/contracts/ci-overlay-flags.md | "Written by" documentation | Updated with shim semantics in 4b97 task 724f |
| plugins/dso/skills/onboarding/SKILL.md | DSO_ASSETS_DIR description | Updated in 4b97 task 724f |
| CLAUDE.md | documentation reference | Updated in S6/e71e |
| tests/fixtures/violation-credentials.sh | comment (line 4) | Updated in 4b97 task 724f |
| tests/scripts/test-ci-llm-review-job.sh | tests that CI job invokes the runner | Updated with CI workflow changes in S3/e596 |
| tests/scripts/test-ci-llm-review-runner.sh | tests the runner script itself | Updated/deleted in S3/e596 |
| tests/scripts/test-claude-md-ci-review.sh | asserts CLAUDE.md references the runner | Updated in S6/e71e |
| tests/scripts/test-host-project-e2e-verify.sh | comment reference (line ~358) | Updated in 4b97 task 724f |
| .test-index | test mapping entry (line 59) | Updated in S3/e596 |

---

*This file is a point-in-time audit. Update dispositions as stories complete.*
