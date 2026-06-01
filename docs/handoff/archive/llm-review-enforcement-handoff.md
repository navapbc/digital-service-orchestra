> **HISTORICAL** — captured during a prior planning iteration. Live system state has evolved.
> For current architecture, see `docs/contracts/sub-pr-enforcement.md` (if exists) and this handoff doc.

# Handoff: LLM Review Enforcement Hardening

## Where we are

Multi-PR remediation of the DSO LLM review enforcement pipeline. Originated from an audit
that found code could merge to main without LLM review having actually completed, and the
"giant diff" failure mode where session→main PRs concatenated thousands of already-shipped
commits into a single 4M-line LLM payload.

### Merged to main

- **PR #422** — F1/F2/F3/F6: session-branch ruleset, not_found→unverified, F3 commit-scoped
  diff for unprovenanced SHAs, CI/GITHUB_ACTIONS env detection in skip-review-check.sh.
- **PR #426** — PR-1: R2 poison-on-failure verifier + cache v3, R3a fail-closed empty diff,
  R10 force-review commit-scoping, R7d dispatcher size cap, R3a v4.1 already-merged SHA
  filter (the PR #425 incident fix), shallow-clone self-heal.

### In flight — PR #432 (worktree branch `worktree-20260528-085216`)

PR-2 + PR-2 follow-up. Latest CI run waiting on background task (see "How to check
status" below). Branch contains:

- **R4** — empty-diff guard in `review-sub-pr.yml`.
- **R5** — concurrency group in `review-sub-pr.yml`.
- **R7a** — `tests/scripts/test-branch-pattern-alignment.sh` (8 assertions; supersedes the
  hardcoded-pattern test in test-provision-ruleset.sh).
- **R7b** — `tests/skills/dso_ci_review/test_region_split_invariant.py` (5 behavioral
  boundary tests for the 3000 LOC / 40 files thresholds).
- **R8** — cross-reference comments + dynamic patterns in `provision-ruleset.sh`.
- **GAP-1 fix** — `review-sub-pr.yml` trigger branches now mirror the source-of-truth file
  (caught by an earlier LLM review on this PR — it ironically flagged the exact drift class
  the patches were meant to eliminate).
- **Empty-patterns-file fail-closed** — provisioner refuses to ship a ruleset with an empty
  include array.
- **Verifier already-merged filter** — `verify-session-provenance.sh` uses
  `git log A..B ^origin/${GITHUB_BASE_REF:-main}` to skip already-shipped commits.
  Aligned with dispatcher's R3a v4.1.
- **ci.yml root-cause fix** — dropped `--depth=1` from the verifier-step `git fetch`. The
  shallow fetch was silently no-op'ing the new filter AND breaking the existing
  `BASE_SHA..SESSION_HEAD` range computation.

### How to check status

```bash
gh pr checks 432
# wait-for-pr task id is in: /private/tmp/claude-502/.../tasks/b5c1z0r29.output
# (or just re-run): bash plugins/dso/scripts/wait-for-pr.sh 432
```

If CI is still slow on the "Verify session provenance" step, look for these expected
signals in the log that confirm the fix worked:

```
git log "$BASE_SHA..$SESSION_HEAD" "^origin/main" --format=...
```

Should produce only the PR's actual commits (3–10), not 6,000+.

## Next steps once PR #432 merges

### PR-3 (live ruleset changes — staged)

1. **R0 verification**: confirm `merge-pipeline-checks` actually reports on session→main PRs
   before promoting it to required.
   ```bash
   gh api repos/navapbc/digital-service-orchestra/commits/$(gh pr view 422 --json mergeCommit -q .mergeCommit.oid)/check-runs \
     --jq '.check_runs[] | select(.name == "merge-pipeline-checks") | {name, status, conclusion}'
   ```
2. **R1-stage**: PATCH ruleset 15629023 to add `Actionlint` + `merge-pipeline-checks` with
   `enforcement: evaluate`. Observe 24h.

### PR-4 (live ruleset activation)

3. **R1-active**: promote ruleset 15629023 to `enforcement: active`.
4. **R9**: PATCH ruleset 16961402 (`DSO Sub-PR Review Enforcement`) to include the full
   12-pattern list from `plugins/dso/config/sub-pr-branch-patterns.txt` (provisioner
   already emits these — the live ruleset just needs re-applying).

### PR-5 (bypass mode flip)

5. **R3**: edit `provision-ruleset.sh:43` to `BYPASS_ACTOR_POLICY="pull_request"`.
   PATCH ruleset 16961402's `bypass_actors[0].bypass_mode` from `always` to `pull_request`.
6. **R3-smoke**: deterministic verification PR (small docs-only change) to validate the
   admin PR-time bypass UI is operational and creates an audit-trail entry.

### Live-state operations not in the plan

- **Main-ruleset drift sync** — `.github/required-checks.txt` lists `review-sub-pr` and
  `merge-pipeline-checks`, but live ruleset 15629023 doesn't enforce them. After R1
  promotes them, they'll be enforced. `review-sub-pr` should be REMOVED from
  required-checks.txt (it belongs only on the session-branch ruleset).

## Plan history (for context)

The remediation plan lives at `/tmp/remediation-plan-review.md` (this is a session-local
scratch file; if it's gone, the merge commit messages and the original audit prompt
below are the canonical sources).

The plan went through 4 review revisions (v1 → v4) before execution. Each revision was
reviewed by an opus subagent. Key learnings:

- Filter-class fixes (PR-1d, verifier filter) need a regression test that anchors the
  specific incident (e.g., PR #425's 6,121-SHA scenario).
- Branch-pattern alignment requires THREE consumers to stay in sync: the source-of-truth
  file, the dispatcher's regex, and the workflow's `pull_request.branches` trigger.
- Test environments need ephemeral commits (not real HEAD SHAs) to avoid
  filter-removes-everything failures.
- `CLAUDE_PLUGIN_ROOT` env var can shadow the actual worktree's plugin directory; tests
  that read configs must use `BASH_SOURCE`-derived paths, not env-based ones.
- The `set +e ... set -e` bracket is required around command substitutions that may fail
  under `set -o pipefail` (otherwise the script exits silently before the error message
  fires).

## The audit prompt (verbatim)

This is the prompt we've used three times — once for the original audit, once for the
re-audit after PR #422 merged, and once independently (without leakage of prior findings)
after PR #426 merged. Use it again after each major PR merges to validate the enforcement
chain end-to-end:

```
You are a Principal Software Developer at a company like Google or USDS. You are a steward
of this codebase; you are invested in the overall quality of the codebase, not just your
changes. TAKE YOUR TIME and FIX PREEXISTING ISSUES you encounter.

Your job is to review this project's GitHub configuration and associated scripts to
determine whether all code merged to main is required to pass through an LLM review process.

The intended design is that smaller 'story' PRs are reviewed and merged into a session
worktree. The session worktree is merged to main, but changes included in 'story' PRs that
have been previously reviewed should not be re-reviewed. The goal of the process is to
ensure all code gets reviewed in smaller chunks that the LLM reviewer can better handle.

Failure modes might include 'story' PRs not completing LLM review, direct commits to the
session worktree not being reviewed, or the LLM attempting to review the entire session
worktree PR diff, including previously reviewed code. Each finding must include specific
references to relevant code and a test case that will demonstrate the failure.
```

Dispatch via:

```python
Agent(
    subagent_type="general-purpose",
    model="opus",
    description="LLM review enforcement audit",
    prompt="<verbatim prompt above>"
)
```

For independent re-validation (no leaked context), spawn a fresh subagent without
mentioning prior findings.

## Key files and concepts

### Source-of-truth files

- `plugins/dso/config/sub-pr-branch-patterns.txt` — branch patterns subject to sub-PR
  review enforcement. Read by both the dispatcher (`_FORCE_REVIEW` regex) and the
  provisioner (ruleset `include` array). Test-branch-pattern-alignment.sh enforces
  consistency across the three consumers (file, dispatcher, provisioner, plus the
  workflow trigger after PR-2).

### Verifier (`verify-session-provenance.sh`)

- Walks `BASE_SHA..SESSION_HEAD`, classifies each commit as `provenanced`, `unprovenanced`,
  or `over_bound`. R2 (PR-1) uses poison-on-failure semantics: any historical failure-class
  conclusion in covering-PR check-runs marks the SHA unverified.
- Cache version 3 (cache_version bumped v2 → v3 to invalidate stale entries that may have
  masked failures under v2's short-circuit-on-first-success logic).
- PR-2 follow-up adds `^origin/${GITHUB_BASE_REF:-main}` to skip already-shipped commits.
  Defaults aligned with dispatcher's `_MAIN_REF`.

### Dispatcher (`llm-review-dispatch-or-skip.sh`)

- R3a v4.1 filter: removes already-merged SHAs from `_DISPATCH_SCOPE_FILE` before generating
  the commit-scoped diff. Critical for the PR #425 incident class (6,121 stale SHAs).
- Self-heals shallow CI checkouts via `git fetch --unshallow` before the filter runs.
- R7d dispatcher-side size cap (5MB / 100 files default; overridable via
  `DSO_DISPATCH_BYTES_CAP` / `DSO_DISPATCH_FILES_CAP`) as defense-in-depth against any
  remaining giant-diff path.
- R10 force-review path narrows to only commits without prior llm-review pass (using
  poison-on-failure semantics consistent with R2).

### Provisioner (`provision-ruleset.sh`)

- Reads `sub-pr-branch-patterns.txt` dynamically at runtime — does NOT hardcode patterns.
- Fails closed if the patterns file is empty or comments-only (PR-2 critical-finding fix).
- Two rulesets: `DSO CI Enforcement` (main branch) and `DSO Sub-PR Review Enforcement`
  (session/worktree branches).

### Live GitHub state

- Ruleset 15629023: `DSO CI Enforcement` (main branch). 8 required checks currently;
  `.github/required-checks.txt` lists 11. Drift to be resolved in PR-3/PR-4.
- Ruleset 16961402: `DSO Sub-PR Review Enforcement` (session/worktree branches). Currently
  includes only the original 5 patterns; needs PATCH to include the full 12 from the
  source-of-truth file. R9 in PR-4.

### Test infrastructure

- `tests/scripts/test-branch-pattern-alignment.sh` — alignment test (8 assertions).
- `tests/skills/dso_ci_review/test_region_split_invariant.py` — runner threshold invariant
  (5 behavioral tests at threshold boundaries).
- `tests/scripts/test-verify-session-provenance.sh` — 35 tests including PR-2 follow-up's
  4 new tests for upstream filter behavior.
- `tests/scripts/test-llm-review-dispatch-or-skip.sh` — 42 tests including PR #425 anchor
  test (50 merged + 2 unmerged → asserts zero merged files leak into dispatched diff).

## Decision log highlights

- **Force-merging PR #422**: used `/dso:fp-recovery` workflow + `DSO_FP_RECOVERY_ACTIVE=1`
  to bypass the post-Phase-F admin-merge block. CI was green except for Script Tests
  failures we'd already addressed. Annotated merge commit per FP-recovery protocol.
- **Withdraw F4**: the v2 review correctly identified that "empty integration scope falls
  back to full PR diff" is working-as-designed (safe fallback), not a gap.
- **B4 preserved in R2**: the `name` filter in the verifier's check-run iteration must be
  retained or unrelated check-runs (e.g., Hook Tests failure) would poison the SHA. Caught
  by the opus reviewer; tested by `test_unrelated_check_runs_do_not_affect_classification`.
- **CLAUDE_PLUGIN_ROOT shadowing**: local test runs need `unset CLAUDE_PLUGIN_ROOT` because
  the session env var points to the main repo's stale plugin copy. CI doesn't have this
  problem.

## Quick context-restore commands

```bash
# Verify branch state
git log --oneline origin/main..HEAD | head -10

# Run the full test suite this session has been touching
unset CLAUDE_PLUGIN_ROOT
bash tests/scripts/test-llm-review-dispatch-or-skip.sh        # 42 tests
bash tests/scripts/test-verify-session-provenance.sh           # 35 tests
bash tests/scripts/test-verify-session-provenance-cases.sh     # 15 tests
bash tests/scripts/test-branch-pattern-alignment.sh            # 8 tests
bash tests/scripts/test-provision-ruleset.sh                   # 20 tests
bash tests/scripts/test-plugin-scripts-no-relative-paths.sh    # 2 tests
python3 -m pytest tests/skills/dso_ci_review/test_region_split_invariant.py  # 5 tests

# Inspect the current PR (in flight)
gh pr view 432 --json state,mergeStateStatus,headRefName,mergedAt
gh pr checks 432
bash plugins/dso/scripts/wait-for-pr.sh 432

# Inspect live GitHub rulesets
gh api repos/navapbc/digital-service-orchestra/rulesets 2>/dev/null | \
  python3 -c "import json,sys; [print(f\"{r['id']}: {r['name']} ({r['enforcement']})\") for r in json.load(sys.stdin)]"

# Live ruleset content
gh api repos/navapbc/digital-service-orchestra/rulesets/15629023 2>/dev/null | jq .
gh api repos/navapbc/digital-service-orchestra/rulesets/16961402 2>/dev/null | jq .

# Verify the latest dispatcher logs show commit-scoped routing (not giant diff)
gh run list --workflow=ci.yml --limit 5 --json databaseId,headBranch,conclusion --jq '.[]'
# Then for any specific run:
# gh run view <run_id> --job <llm-review-job-id> --log 2>/dev/null | grep -E "filtered|commit-scoped|FORCE_REVIEW|DECISION"
```
