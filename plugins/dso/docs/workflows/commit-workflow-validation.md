# Commit Workflow — Local Validation

This file contains the local-validation steps extracted from `COMMIT-WORKFLOW.md` (originally Steps 1.5, 2, 3, 3a, 4.5, and 5; now renumbered as Steps 1–6 of this file). It is referenced from the parent commit workflow's Step 3 (enforcement-strategy gate) — when `enforcement.strategy=local`, the parent workflow executes the steps below in order; when `enforcement.strategy=ci`, these steps are deferred to CI.

Every command and breadcrumb log line in this file is preserved verbatim from the original COMMIT-WORKFLOW.md. Do not paraphrase or restructure when consuming.

---

## Always-On vs Gated Hooks

The pre-commit pipeline mixes two categories of hooks. Understanding which is which matters when diagnosing why a commit was blocked or when reasoning about what `enforcement.strategy=ci` actually defers.

### Always-On Hooks (6)

These run on every commit regardless of `enforcement.strategy`. They enforce structural invariants that must hold at all times — bypassing them would corrupt the repository, not merely defer validation.

1. `check-portability.sh` — blocks hardcoded paths (suppress with `# portability-ok`)
2. `check-shim-refs.sh` — blocks direct plugin script references (suppress with `# shim-exempt: <reason>`; use `.claude/scripts/dso <script-name>` shim instead)
3. `check-contract-schemas.sh` — validates contract markdown structure
4. `check-referential-integrity.sh` — blocks dead path references in instruction files
5. `check-plugin-self-ref.sh` — blocks literal plugin-tree paths (e.g. ${CLAUDE_PLUGIN_ROOT}/...) inside plugin scripts; no suppression annotation — use `_PLUGIN_ROOT` / `_PLUGIN_GIT_PATH`
6. `pre-commit-enforcement-boundary-check.sh` — enforces the enforcement-hook / non-enforcement-hook boundary at commit time

### Gated Hooks (3)

These honor `enforcement.strategy`. When `enforcement.strategy=ci`, they are skipped locally and executed in CI instead. When `enforcement.strategy=local` (default), they run on every commit.

1. `pre-commit-test-gate.sh` — verifies test status per staged file; centrality-aware
2. `pre-commit-review-gate.sh` — enforces review-status, allowlist, and diff-hash match
3. `pre-commit-test-quality-gate.sh` — detects anti-patterns in staged test files

### Network partition during CI

> **Caveat — `enforcement.strategy=ci` and network partition.** When `enforcement.strategy=ci` is configured, the gated hooks above are deferred to CI. If the network is partitioned at push time (or CI is unavailable for any reason), `git commit` and `git push` will succeed locally without ever running the gated hooks — leaving unvalidated code committed to the branch and potentially merged before CI catches up. Operators choosing `enforcement.strategy=ci` accept this risk in exchange for faster local commits. Operators in regulated or high-assurance environments should prefer `enforcement.strategy=local`, which runs all gates on every commit regardless of network state.

---

## Step 1: Changed Integration/E2E Tests

If any integration or e2e test files changed, run only those files now. This prevents broken tests from being committed when the full suite is excluded from the standard commit gate.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
TEST_CHANGED_CMD="$(".claude/scripts/dso read-config.sh" commands.test_changed)"
if [ -z "$TEST_CHANGED_CMD" ]; then
    echo "commands.test_changed not configured — skipping changed-test step"
    .claude/scripts/dso commit-step skip test "test_changed not configured"
    # continue to Step 2
else
    .claude/scripts/dso commit-step test "$TEST_CHANGED_CMD"
fi
```

- **Integration tests fail**: DB is not running. Start it with `make db-start` and re-run. Fix the test if it is broken.
- **E2E tests fail**: App is not running. Start it with `make start` and re-run. Fix the test if it is broken.
- **No changed integration/e2e files**: Script exits silently. Continue to Step 2.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-1-changed-tests" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

### Test Failure Delegation (Step 1)

If integration or E2E tests fail after environment checks (DB/app running), apply this decision gate:

**Fix inline**: Single obvious failure (typo, missing import, one-line fix) — fix it and re-run.

**Delegate to sub-agent** (via [TEST-FAILURE-DISPATCH.md](TEST-FAILURE-DISPATCH.md)):
- More than 1 test fails, OR
- 1 test fails and an inline fix attempt did not resolve it.

Dispatch procedure:

1. **Build the input payload** using the integration/E2E test command that failed:

```bash
TEST_CHANGED_CMD="$(".claude/scripts/dso read-config.sh" commands.test_changed)"
TEST_COMMAND="$REPO_ROOT/$TEST_CHANGED_CMD"
# EXIT_CODE and STDERR_TAIL come from the ALREADY-FAILED test run above.
# Do NOT re-run the tests — capture from the original failure.
# EXIT_CODE=<exit code from the failed test run>
# STDERR_TAIL=<last 50 lines of output from the failed test run>
CHANGED_FILES=$(git diff --name-only)
```

2. **Set context** based on failure type:
   - Integration test failure: `context="sprint-ci-failure"`
   - E2E test failure: `context="commit-time"`

3. **Sub-agent type by failure category** (see [TEST-FAILURE-DISPATCH.md](TEST-FAILURE-DISPATCH.md) for full dispatch procedure):

   | Failure Category | Sub-Agent Type |
   |-----------------|----------------|
   | Unit test failure | `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`) |
   | Type / lint error | `discover-agents.sh` routing category `mechanical_fix` |
   | Multi-file / complex (CI-only) | `error-debugging:error-detective` |

4. **Parse the result**:
   - `RESULT: PASS` — re-run the config-driven test command (`$REPO_ROOT/$TEST_CHANGED_CMD`) to confirm the fix, then continue to Step 2.
   - `RESULT: FAIL` — increment attempt counter and retry with escalated model. If attempt exceeds `review.max_resolution_attempts` (default: 5), escalate to user.
   - `RESULT: PARTIAL` — log concerns via `.claude/scripts/dso ticket comment`, continue to Step 2 with caveats.

5. **Fallback**: Sub-agent timeout (>5 min) or malformed output — fall back to inline fix attempt and restart from Step 1.

## Step 2: Format

Run formatting on modified files so file edits are complete before staging.

```bash
FORMAT_CHECK_CMD="cd app && make format-modified"
.claude/scripts/dso commit-step format "$FORMAT_CHECK_CMD"
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-2-format" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 3: Lint and Type Check

Run lint and type checks before staging. Any tool that may edit files must run before `git add`.

```bash
LINT_CMD="cd app && make lint-ruff 2>&1 | tail -3"
.claude/scripts/dso commit-step lint "$LINT_CMD"
```

```bash
LINT_CMD="cd app && make lint-mypy 2>&1 | tail -5"
.claude/scripts/dso commit-step lint "$LINT_CMD"
```

On success, only the summary lines are needed. If either exit code is non-zero, re-run with full output to see errors.

If either check fails, fix the issue and **restart from Step 1**.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-3-lint-typecheck" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 4: Write Validation State File

After Steps 1–3 all pass, write a validation state file so the review workflow can skip redundant re-validation:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Resolve CLAUDE_PLUGIN_ROOT if not set by the caller (e.g., manual run outside Claude Code)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _cfg="$REPO_ROOT/.claude/dso-config.conf"
    if [[ -f "$_cfg" ]]; then
        CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$_cfg" 2>/dev/null | cut -d= -f2-)"
    fi
    # Final fallback: read dso.plugin_root from config
    if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2-)"
    fi
fi
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
echo "passed" > "$ARTIFACTS_DIR/validation-status"
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-4-validation-state" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 5: Record Test Status

Run `record-test-status.sh` **after** `git add -u` (Step 5 of the parent COMMIT-WORKFLOW.md) so that the recorded diff hash matches the staged index — the pre-commit test gate validates against the staged hash, not the working-tree hash.

The load-bearing defense against stale-diff status writes is the diff_hash check inside `${CLAUDE_PLUGIN_ROOT}/hooks/pre-commit-test-gate.sh` — it rejects any `test-gate-status` whose `diff_hash` does not match the current staged tree, regardless of how the status was recorded.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-test-status.sh"
```

- **exit 0**: all associated tests passed (or no associated tests found) — continue to Step 6 (Review Gate).
- **exit 144**: test runner was terminated; follow the actionable guidance printed by `record-test-status.sh`. Use `test-batched.sh` to run the tests in time-bounded chunks:
  ```bash
  .claude/scripts/dso test-batched.sh --timeout=50 "bash tests/hooks/test-<name>.sh"
  ```
  When `test-batched.sh` runs out of time, it emits a **Structured Action-Required Block**:
  ```
  ════════════════════════════════════════════════════════════
    ⚠  ACTION REQUIRED — TESTS NOT COMPLETE  ⚠
  ════════════════════════════════════════════════════════════
  RUN: TEST_BATCHED_STATE_FILE=... bash .../test-batched.sh ...
  DO NOT PROCEED until the command above prints a final summary.
  ════════════════════════════════════════════════════════════
  ```
  Run the command shown on the `RUN:` line in subsequent calls until the summary appears, then re-run Step 5.
- **exit non-zero (other)**: tests failed; fix the failures and **restart from Step 1**.

> **NEVER add RED markers to `.test-index` to bypass a test gate failure.** RED markers (`[test_name]` entries in `.test-index`) are exclusively for TDD — they mark tests that are expected to fail because the feature under test is not yet implemented. If the test gate blocks due to pre-existing failures unrelated to your change, create a bug ticket (`.claude/scripts/dso ticket create bug "<test failure description>"`) and fix the test. Do NOT add a marker to mask the failure.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-5-record-test-status" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 6: Review Gate

When `enforcement.strategy=ci`, the review gate is deferred to CI. Emit skip markers for both review artifacts and proceed to commit:

```bash
ENFORCEMENT_STRATEGY="$(".claude/scripts/dso read-config.sh" enforcement.strategy)"
if [[ "$ENFORCEMENT_STRATEGY" == "ci" ]]; then
    .claude/scripts/dso commit-step skip reviewer-record "enforcement.strategy=ci"
    .claude/scripts/dso commit-step skip classifier-dispatch "enforcement.strategy=ci"
    # proceed to commit — review runs in CI
fi
```

Decide whether a review is needed:

- **`enforcement.strategy=ci`**: Emit `.skipped` markers for `reviewer-record` and `classifier-dispatch` (shown above), then proceed to commit. CI enforces the review gate.
- **Review ran earlier this session and no files changed since**: Skip to Step 6 of the parent COMMIT-WORKFLOW.md (Commit).
- **No recent review, or files changed since the last review**: Execute the review workflow (REVIEW-WORKFLOW.md). If you have already read this file earlier in this conversation and have not compacted since, use the version in context. Note: Steps 1–4 above already ran format/lint/type-check and wrote the validation-status file, so REVIEW-WORKFLOW.md Step 1 (auto-fix pass) will skip via the fresh validation-status check. This ensures the diff hash captured in REVIEW-WORKFLOW.md Step 2 reflects the post-auto-fix state and will not be invalidated by pre-commit hooks.
- **The commit in Step 6 of the parent COMMIT-WORKFLOW.md is blocked** with "Review is stale" or "No code review recorded": Run REVIEW-WORKFLOW.md, then retry the commit step. Do NOT inspect, copy, or modify review state files — the commit gate enforces correctness and any workaround will be caught at the merge step.

If review fails, the review workflow's Autonomous Resolution Loop handles fix/defend attempts automatically (up to `review.max_resolution_attempts`, default: 5). If it escalates to you (the orchestrator), fix the issues and **restart from Step 1** (not Step 6).

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-6-review-gate" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```
