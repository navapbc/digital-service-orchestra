# CI Integration

How the DSO plugin participates in CI: llm-review orchestration, version resolution, and the two-channel release model.

## CI llm-review orchestrator

`${CLAUDE_PLUGIN_ROOT}/scripts/dso_ci_review/` is a Python package; `ci-llm-review-runner.sh` is a 29-line shim that resolves `_PLUGIN_ROOT` and execs `python3 -m dso_ci_review.runner`. (`llm-api-call.sh` was deleted in S3.) # shim-exempt: doc reference

- Auto-detects local-checkout vs fetched-assets mode via marker file `${CLAUDE_PLUGIN_ROOT}/.dso-source-of-truth`. # shim-exempt: doc reference
- Parallel overlay dispatch (`&` fan-out + single `wait`).
- Does **not** consult `check-usage.sh` — CI is not subject to interactive throttling.

## CI version resolution (3-tier)

Host-project CI uses the local plugin checkout when the marker file is present; falls back to `dso` channel, then `dso-dev` channel.

## Two-channel release model

The plugin marketplace (`marketplace.json`) exposes two channels:

- `dso` — stable; pinned to a release tag after the first `scripts/release.sh` run.
- `dso-dev` — dev; pinned to `main` HEAD.

Advancing the stable channel requires running `scripts/release.sh` at the repo root, which enforces 10 precondition gates (semver validation, gh auth, tag uniqueness, on-main, clean tree, upstream sync, CI green, `validate.sh --ci`, marketplace.json validity, and interactive confirmation) before creating and pushing the release tag.

Consumers who want stability install `dso`; consumers who want every merge install `dso-dev`. See `VERSIONING.md` for the broader release discipline.

## CI llm-review: Strategy E — Region-Split FALLBACK

When a PR diff exceeds **400 LOC or 15 files**, `_should_region_split()` returns True and the review pipeline switches to file-clustered parallel review instead of submitting the full diff to a single reviewer pass.

- `_cluster_files()` groups changed files by directory prefix into up to 5 clusters.
- Each cluster is reviewed in parallel by tier-appropriate reviewers (same tier selection as the standard path).
- Findings from all clusters are deduplicated via `deduplicate_region_findings()`: when the same finding appears in multiple clusters, the MAX severity is kept and both rationales are merged.
- A final Opus arch synthesis pass runs over the combined finding set to surface cross-cluster boundary issues that per-cluster reviewers cannot see.

Key modules: `dso_ci_review/region_split.py` (split logic, clustering, deduplication), `dso_ci_review/findings.py` (finding data model). No additional configuration is required — the 400 LOC / 15-file threshold is hardcoded.

## Unified Per-Branch CI Review Architecture (ci-pr mode)

In `ci-pr` mode (`dso.workflow=ci-pr`), the sprint uses a unified per-branch review model where all code review happens in CI via GitHub Actions, not locally.

### Merge paths

- **session→main is the sole merge path** for sprint and debug-everything in ci-pr mode. Sub-branch story PRs merge into the session branch; the session branch PR merges into main. No direct sub-branch → main merges are allowed.
- Sub-branches (`story/<epic-id>/<story-id>`) merge into the session branch after CI test/lint jobs pass.

> **KNOWN GAP (tracked under remediation epic; post-mortem bug 576b-a6c7-3de3-4eef)**: Sub-branch internal LLM review is currently NOT enforced. `.github/workflows/per-branch-review.yml` (which previously gated sub-branch PRs with per-story LLM review) was deleted by story 20d7-09d6 to enforce a no-duplicate-checks-per-SHA invariant required by epic b575's cycle-ledger machinery. `ci.yml`'s `llm-review` job is gated to `base_ref == 'main'` and does NOT fire on sub-branch PRs. `/dso:review` is HARD-GATED to no-op under `dso.workflow=ci-pr`. External advisory reviewers (CodeRabbit, Gitar) may run but are NOT required checks. Internal LLM review currently fires only at the cumulative session→main PR. The remediation epic restores per-sub-branch internal review with ledger keying (`(pr_number, sha)` instead of `sha` alone) so per-sub-PR and session→main reviews can coexist without double-counting.

### `ci.yml` — sole PR-side LLM-review entry point (story 20d7-09d6) — gated to base=main

`ci.yml`'s `llm-review` job is currently the sole CI workflow that runs LLM review. It is gated to `base_ref == 'main'` (see ci.yml:314), so it fires ONLY on the session→main PR. It does NOT fire on sub-branch PRs (`story/*` and `bug-batch/*` targeting the session branch). Responsibilities (when it fires):

- Resolves the review base via a resolver script. The resolver consults the `SPRINT_SESSION_ID` repo variable (set by sprint Phase A) as one input, but the actual base resolution may also consider the branch's PR target, the most recent `story/<epic-id>/...` parent on the session branch, and other signals. The resolver is the source of truth — the repo variable is not consulted directly by the workflow.
- Computes the integration review scope (see "Integration review scope definition" below).
- Dispatches the LLM review orchestrator (`ci-llm-review-runner.sh`) against that scoped diff.
- Blocks the session→main PR merge until the review passes.

### `verify-session-provenance.sh` — integration review pre-step

Before the session→main PR triggers the full integration LLM review, `verify-session-provenance.sh` runs as a pre-step to identify which commits require integration-level scrutiny. Its outputs narrow the review scope:

- **Cross-branch files**: files modified by commits from ≥ 2 distinct sub-branches (potential interaction surface).
- **Un-provenanced commits**: commits on the session branch that lack a `DSO-Story-Merge` trailer or equivalent GitHub PR merge provenance (potential leakage).

If the resulting scope is empty (all commits are provenanced and no files span multiple sub-branches), the integration review job exits 0 immediately without dispatching any LLM reviewer.

### `resolve-session-branch.sh` — session branch discovery

`resolve-session-branch.sh` provides a 3-step fallback to determine the current session branch name (matches the script's actual implementation):

1. `gh pr view --json headRefName` of the currently-checked-out PR (when a PR exists for the branch).
2. `SPRINT_SESSION_ID` repo variable (set by Phase A; consulted when no open PR is found).
3. Fail-fast with an actionable error message — does NOT silently fall back to the current git branch.

This script is called by Phase F during story PR creation to set `STORY_PR_BASE`, ensuring story PRs always target the correct session branch.

### Integration review scope definition

"Integration scope" is intentionally narrow: only files that appear in commits from two or more distinct story branches, plus any commits that bypassed per-branch review. Commits that touch only one story's files are intended to be excluded from integration-level LLM review (their review would be recorded by the per-sub-branch review job when present).

> **NOTE**: The integration-scope narrowing logic in `ci.yml` was disabled by bug 1624-5fb9 (reverted to full-diff fallback). Currently, the session→main `llm-review` runs against the FULL cumulative diff, not the narrowed integration scope. Re-enabling incremental scope is in the remediation epic.

## Merge-to-main pipeline

Phases: `sync → merge → version_bump → validate → push → archive → ci_trigger → comment_response`.

- PR mode (`dso.workflow=ci-pr`) appends a `remediate` phase (bounded retry loop, per-tier ceiling=5, global ceiling=15; exit 2 = remediation exhaustion with escalation JSON on stdout; exit 1 = pre-remediation failure).
- State file: `/tmp/merge-to-main-state-<branch>.json` (4h TTL); `--resume` continues from checkpoint.
- See `CONFIGURATION-REFERENCE.md` for the `dso.workflow` key (`ci-pr` or `local`). Legacy keys `merge.strategy` and `enforcement.strategy` are deprecated — use `dso.workflow` instead.

### Source-branch version-bump phase (PR mode only)

In `dso.workflow=ci-pr` (PR mode), `${CLAUDE_PLUGIN_ROOT}/scripts/merge-to-main-pr.sh` runs a **pre-merge** `_phase_source_branch_version_bump` step on the source/session branch before the PR is created or queued for merge. This is distinct from the legacy post-merge bump path used by direct mode.

**What the phase does:**

1. Resolves `version.file_path` from `dso-config.conf` (or the `VERSION_FILE_PATH` env var). If unconfigured or the file is absent, the phase is a no-op.
2. **Idempotency gate**: runs `git diff --quiet -- <version-file>`. If the file is already modified on disk vs HEAD (e.g. from an interrupted prior attempt), the bump step is skipped and only the commit/push steps run — preventing a double-bump.
3. Calls `bump-version.sh --<bump-type>` (default: `--patch`) with `DSO_MERGE_TO_MAIN_PHASE=version_bump` set so the branch guard in `bump-version.sh` passes.
4. Stages the version file and `package-lock.json` (when the version file is `package.json`).
5. Commits with a `DSO-Story-Merge: <story-id>` trailer so `verify-session-provenance.sh` treats the bump commit as provenanced and excludes it from the un-provenanced commit count. When no story-id is available, the trailer is omitted.
6. Pushes the bump commit to `origin HEAD` **before** the PR merge is initiated. Push failure aborts the pipeline (exit non-zero); the merge never proceeds with an unpushed bump.

**Post-merge no-op detection:**

After the PR merges to `origin/main`, the post-merge `_phase_version_bump` runs `git log HEAD^1..HEAD --format=%B -- <version-file>` and greps for a `DSO-Story(-Merge)?:` trailer. If the trailer is found, the source-branch bump already landed in the merged history, and `_phase_version_bump` marks itself complete without re-bumping. If the trailer is absent (old workflow, or no version file), it falls through to the legacy post-merge bump path (see below).

**Design rationale:** bumping on the source branch rather than post-merge main ensures the version bump appears in the per-story PR history, avoids race conditions with concurrent merges, and makes the post-merge phase a pure no-op check.

**Bump scope:** every session→main PR that has `version.file_path` configured receives a version-bump commit on the source branch. There is no per-PR opt-out mechanism. If the bump-version logic detects no version-file change (version already at the bumped value, e.g. after a retry), the phase commits nothing and returns without error.

### Legacy post-merge bump path (direct mode and fallthrough)

`merge-to-main-direct.sh` retains the original post-merge bump behavior: after the merge commit lands on `main`, the `_phase_version_bump` function runs `bump-version.sh`, stages the result, and amends or commits directly on `main`. This path is intentionally **not** changed by S5 — direct mode has no PR workflow, so a pre-merge source-branch bump would require non-trivial architectural changes out of scope for this story.

When running in PR mode with `--resume` on a pipeline that was started *before* S5 (state file shows `version_bump` in `completed_phases` but no source-branch bump trailer), the resume-skip guard fires first and the legacy path is never reached. Pre-S5 in-flight pipelines that have not yet reached `version_bump` fall through to the legacy bump with a deprecation log line (`"post-merge version_bump: no source-branch bump detected — running legacy post-merge bump (deprecated in S5)"`).

The `_try_reset_stale_version_bump` helper (which detects and discards orphan version-bump commits on local `main`) is direct-mode-only and is explicitly skipped in PR mode.
