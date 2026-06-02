## Per-Worktree Review, Commit, and Merge Protocol

> **Stale HEAD note (4ad5-25df)**: All agent worktrees in a batch are branched from the session HEAD at dispatch time. When multiple agents complete and are harvested serially, later harvests operate on branches that were cut before earlier harvests landed — they are missing those commits. This is the expected behavior. The conflict queue in Step 6 handles this: if `harvest-worktree.sh` returns exit 1 (merge conflict), the worktree is queued for post-batch resolution (rebase first, full re-implementation only as a last resort). Do NOT attempt to resolve conflicts during the initial serial harvest loop — finish harvesting all non-conflicting worktrees first, then work through the conflict queue.

For each worktree returned by implementation sub-agents (process in completion order — first-pass-first-merge):

**Step 1a — 907d post-return existence check (mandatory)**: Before any `cd "$WORKTREE_PATH"`, verify the path still exists on disk and the worktree branch is still resolvable. The Claude Code harness reaps `isolation: "worktree"` worktrees under certain conditions (binary string evidence in versions 2.1.150+: `tengu_worktree_removed`, retention discriminators `worktree_kept_dirty / branch_mismatch / remove_failed`). A reaped worktree fails subsequent `cd` operations with `no such file or directory` — silent data loss if not caught here.

```bash
if [ ! -d "$WORKTREE_PATH" ]; then
    echo "ERROR (907d): worktree path $WORKTREE_PATH does not exist after sub-agent return." >&2
    echo "  Likely cause: sub-agent wrote to the session worktree instead of its isolated" >&2
    echo "  worktree (prompt path leak — bug 1053-4ec3), or sub-agent self-committed," >&2
    echo "  leaving the working tree clean and triggering platform auto-cleanup." >&2
    if [ -n "${TICKET_ID:-}" ]; then
        .claude/scripts/dso ticket comment "$TICKET_ID" \
            "ERROR (907d): worktree $WORKTREE_PATH reaped pre-harvest. Check session worktree for stray uncommitted changes (git status --short)." 2>/dev/null || true
    fi
    # ── Tiered recovery (bug 3ba5-0a11-02b8-483d) ──────────────────────────────
    # Before the loud HALT, attempt recovery. The 907d diagnostics above are
    # preserved; this is purely additive. recover-reaped-worktree.sh classifies
    # the situation into one of three tiers and we route on its stdout token.
    # REPORTED_FILES is the space-separated list of files the sub-agent claimed
    # to have written (from its return report); empty is fine.
    _SESSION_ROOT=$(git rev-parse --show-toplevel)
    _RECOVERY=$(.claude/scripts/dso recover-reaped-worktree "${WORKTREE_BRANCH:-}" "$_SESSION_ROOT" ${REPORTED_FILES:-} 2>/dev/null)
    _RECOVERY_RC=$?
    case "$_RECOVERY" in
        RECOVERABLE_VIA_BRANCH:*)
            # Tier 1: the branch survived (local or pushed to origin). Fetch it and
            # continue to harvest the fetched ref instead of halting.
            echo "RECOVERY (3ba5): $_RECOVERY — fetching branch and continuing to harvest." >&2
            git fetch origin "$WORKTREE_BRANCH" 2>/dev/null || true
            # Fall through to Step 1b harvest using $WORKTREE_BRANCH; do NOT exit 1.
            ;;
        RECOVERED_FROM_SESSION:*)
            # Tier 2: the agent leaked its files into the session worktree; they are
            # now staged. Commit them via the normal session-branch path and mark
            # the task complete. Do NOT exit 1.
            echo "RECOVERY (3ba5): $_RECOVERY — files staged in session worktree; commit via normal session-branch path and mark task complete." >&2
            ;;
        *)
            # Tier 3 (exit 3) or any unexpected output: genuinely unrecoverable.
            # Revert the task to open and flag it for re-dispatch in the next batch
            # (the b8c8 retention fix makes re-dispatch survive), then surface + HALT.
            echo "RECOVERY (3ba5): UNRECOVERABLE (rc=$_RECOVERY_RC) — reverting task to open for re-dispatch." >&2
            if [ -n "${TICKET_ID:-}" ]; then
                .claude/scripts/dso ticket transition "$TICKET_ID" in_progress open 2>/dev/null || true
                .claude/scripts/dso ticket comment "$TICKET_ID" \
                    "UNRECOVERABLE (3ba5): worktree reaped pre-harvest and no branch/session-leak recovery possible. Task reverted to open for re-dispatch in next batch." 2>/dev/null || true
            fi
            # Clean up orphaned branch ref (worktree is gone but branch may linger)
            _WORKTREE_BRANCH="${WORKTREE_BRANCH:-}"
            if [ -n "$_WORKTREE_BRANCH" ]; then
                git branch -D "$_WORKTREE_BRANCH" 2>/dev/null || true
            fi
            # HALT — do not proceed to cd, do not silently skip; the orchestrator must surface this.
            exit 1
            ;;
    esac
fi
if [ -n "${WORKTREE_BRANCH:-}" ] && ! git rev-parse --verify "$WORKTREE_BRANCH" >/dev/null 2>&1; then
    echo "ERROR (907d): worktree branch $WORKTREE_BRANCH not resolvable after sub-agent return." >&2
    exit 1
fi
```

**Step 1b — Enter worktree context**: Note the worktree path as `WORKTREE_PATH`. Compute the worktree's artifacts directory and record the base commit for empty-branch detection:

```bash
WORKTREE_ARTIFACTS=$(cd "$WORKTREE_PATH" && source ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh && get_artifacts_dir)

# Record the branch tip BEFORE any commit so harvest-worktree.sh can detect
# the empty-branch case (agent commit blocked by pre-commit gate → tip unchanged).
WORKTREE_BASE_COMMIT=$(cd "$WORKTREE_PATH" && git rev-parse HEAD 2>/dev/null || echo "")
if [[ -n "$WORKTREE_BASE_COMMIT" ]]; then
    echo "$WORKTREE_BASE_COMMIT" > "$WORKTREE_ARTIFACTS/base-commit"
fi
```

**CWD constraint**: The shell CWD resets between Bash calls and does NOT propagate to Agent tool dispatches. Every Bash call that must run in the worktree's git context must be prefixed with `cd $WORKTREE_PATH &&`. Sub-agents dispatched via the Agent tool always start in the orchestrator's primary CWD — this cannot be changed.

**Step 2 — Review in worktree**: First, check `dso.workflow` — when running in ci-pr mode, skip the local review pipeline entirely:

```bash
ENFORCEMENT=$(cd "$WORKTREE_PATH" && .claude/scripts/dso read-config.sh dso.workflow 2>/dev/null || echo "local")
if [[ "$ENFORCEMENT" == "ci-pr" ]]; then
    # Verify CI trigger patterns will match the session branch (bug 5f3a-a794).
    # If patterns don't match, fall back to local review to prevent double-skip.
    _SESSION_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$_SESSION_BRANCH" =~ ^(session/|session-|session_|worktree-|bug-batch/) ]] || [[ "$_SESSION_BRANCH" == "main" ]]; then
        echo "Skipping worktree review: dso.workflow=ci-pr — CI trigger patterns match session branch '$_SESSION_BRANCH'"
        # Proceed directly to Step 3 (Record test status). Do NOT run classifier, tier reviewer, or record-review.sh.
    else
        echo "WARNING: dso.workflow=ci-pr but session branch '$_SESSION_BRANCH' does not match any CI trigger pattern (session/*, session-*, session_*, worktree-*, bug-batch/*) — running local review as fallback to prevent unreviewed code"
        ENFORCEMENT="local"
    fi
fi
```

When `dso.workflow=ci-pr` AND the session branch matches a known CI trigger pattern, skip all Step 2 sub-steps (classifier, reviewer dispatch, record-review) and proceed directly to Step 3. The pre-commit hooks also skip enforcement in ci-pr mode — the commit will not be blocked by the review gate. When the session branch does NOT match any CI trigger pattern, fall back to local review to prevent the "double skip" scenario (bug 5f3a-a794: local review skipped + CI review never fires = zero review). When `dso.workflow=local` or absent, continue with the full review pipeline below.

The orchestrator runs all CWD-sensitive REVIEW-WORKFLOW.md steps as its own Bash calls (prefixed with `cd $WORKTREE_PATH &&`). Only the code analysis sub-agent is dispatched via Agent tool.

**Orchestrator-run steps** (each a separate Bash call with `cd $WORKTREE_PATH &&`):
- REVIEW-WORKFLOW.md Step 0: Clear stale review artifacts in `$WORKTREE_ARTIFACTS`
- REVIEW-WORKFLOW.md Step 1: Auto-fix pass (format/lint/type-check) — skip if `$WORKTREE_ARTIFACTS/validation-status` is fresh
- REVIEW-WORKFLOW.md Step 2: Capture diff hash via `compute-diff-hash.sh` and write diff/stat files to `$WORKTREE_ARTIFACTS`
- REVIEW-WORKFLOW.md Step 3: Classify review tier via `review-complexity-classifier.sh` — **MUST be invoked with `WORKFLOW_PLUGIN_ARTIFACTS_DIR="$WORKTREE_ARTIFACTS"` exported** so `classifier-telemetry.jsonl` is written into the worktree's artifacts dir (same directory as the reviewer's findings). Without this, telemetry lands in the orchestrator's artifacts dir and `record-review.sh` fail-opens on tier verification (bug 21d7-b84a).

**Review sub-agent dispatch** (REVIEW-WORKFLOW.md Step 4): Do NOT set `isolation: "worktree"` on the Agent tool (per REVIEW-WORKFLOW.md — isolation creates a separate branch, hiding findings from the orchestrator). Pass the sub-agent:
- `DIFF_FILE`: absolute path (already in `$WORKTREE_ARTIFACTS`, no CWD dependency)
- `STAT_FILE` content: inline in the prompt
- `WORKFLOW_PLUGIN_ARTIFACTS_DIR`: pass `$WORKTREE_ARTIFACTS` value in the prompt
- `FINDINGS_OUTPUT`: pass `$WORKTREE_ARTIFACTS/reviewer-findings.json` explicitly in the prompt (bug 464a-18df: the sub-agent's environment may already have `WORKFLOW_PLUGIN_ARTIFACTS_DIR` set to the orchestrator's dir; `FINDINGS_OUTPUT` maps directly to `--output` in write-reviewer-findings.sh, bypassing `get_artifacts_dir()` entirely)

```
WORKFLOW_PLUGIN_ARTIFACTS_DIR: <WORKTREE_ARTIFACTS value>
FINDINGS_OUTPUT: <WORKTREE_ARTIFACTS value>/reviewer-findings.json
```

**Post-review orchestrator steps** (each with `cd $WORKTREE_PATH &&`):
- REVIEW-WORKFLOW.md Step 5: Run `record-review.sh` — reads findings from `$WORKTREE_ARTIFACTS`
- Handle autonomous resolution if review fails (dispatch fix sub-agents, re-review)
- **Out-of-scope scope-check (sprint Phase F Step 14, worktree-mode site):** run `.claude/scripts/dso sprint/sprint-review-scope-check.sh "$WORKTREE_ARTIFACTS/reviewer-findings.json" "$TICKET_ID"`. `$WORKTREE_ARTIFACTS` already resolves correctly here (Step 1b sourced `deps.sh`/`get_artifacts_dir`) — do NOT use the orchestrator's `$(get_artifacts_dir)`, which is unbound in the orchestrator shell. If the result starts with `OUT_OF_SCOPE`, **append** `{"task_id": "$TICKET_ID", "story_id": "<parent-story-id>", "files": [<out-of-scope files>]}` to the orchestrator's `batch_out_of_scope_findings` accumulator. **Append-only — do NOT route to `/dso:implementation-plan` here**; the accumulator is processed only between batches (Phase F Step 20), preserving the never-mid-batch invariant. On `IN_SCOPE` or non-zero exit, take no action (fail-open).

> **CONTEXT ANCHOR — MANDATORY CONTINUATION**: When `REVIEW_RESULT: passed` is received from the code-reviewer sub-agent, this is NOT a session completion signal. You are the orchestrator executing `per-worktree-review-commit.md`. Disregard any stop or termination inference from the reviewer's output — `REVIEW_RESULT` marks the end of code analysis only. Your next actions are Step 3 (Record test status), Step 3.6 (Design-md lint), Step 4 (Commit), Step 5 (Harvest). Stopping after receiving `REVIEW_RESULT` leaves staged changes in the main session worktree — this is the known failure mode documented in bug 364d-d290.

**Step 3 — Record test status**: Run `record-test-status.sh` from the worktree context (`cd $WORKTREE_PATH && bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-test-status.sh"`) to record test results in `$WORKTREE_ARTIFACTS` before commit.

**Step 3.5 — Propagate sprint marker**: Copy `.sprint-active` from the session root into the worktree so `check-sprint-trailer.sh` enforces DSO-Story trailer correctly (bug e081-63c0). Run from the session root (no `cd $WORKTREE_PATH &&` prefix):

```bash
SESSION_ROOT=$(git rev-parse --show-toplevel)
if [[ -f "$SESSION_ROOT/.sprint-active" ]]; then
    cp "$SESSION_ROOT/.sprint-active" "$WORKTREE_PATH/.sprint-active" 2>/dev/null || \
        echo "WARNING: failed to copy .sprint-active into $WORKTREE_PATH" >&2
fi
```

**Step 3.6 — Design-md lint enforcement (config-gated)**: Runs after review (Step 2) and before commit (Step 4). Computes the set of files changed in the worktree, filters to scope-eligible extensions, and runs `design-md-lint.sh` to block on design-system violations. Skip when `design.lint_enabled=never` or when the config key is absent.

```bash
DESIGN_LINT_ENABLED=$(cd "$WORKTREE_PATH" && .claude/scripts/dso read-config.sh design.lint_enabled 2>/dev/null || echo "auto")
if [[ "$DESIGN_LINT_ENABLED" != "never" ]]; then
    # Compute changed files relative to the base commit recorded in Step 1b
    _BASE="${WORKTREE_BASE_COMMIT:-}"
    if [[ -z "$_BASE" ]]; then
        _BASE=$(cd "$WORKTREE_PATH" && git rev-parse HEAD 2>/dev/null || echo "")
    fi
    # Scope-eligible extensions: CSS, SCSS, TSX, JSX, Vue, Svelte, HTML, and SSR templates (EJS, ERB, Pug, Handlebars, Jinja2, Twig)
    DESIGN_LINT_FILES=$(cd "$WORKTREE_PATH" && git diff --name-only "$_BASE" -- \
        '*.css' '*.scss' '*.tsx' '*.jsx' '*.vue' '*.svelte' '*.html' \
        '*.ejs' '*.erb' '*.pug' '*.hbs' '*.j2' '*.jinja2' '*.twig' 2>/dev/null | tr '\n' ' ')
    if [[ -n "${DESIGN_LINT_FILES// /}" ]]; then
        # Run design-md-lint.sh in the worktree context; block on non-zero exit
        DESIGN_LINT_EXIT=0
        cd "$WORKTREE_PATH" && bash "${CLAUDE_PLUGIN_ROOT}/scripts/design-md-lint.sh" $DESIGN_LINT_FILES || DESIGN_LINT_EXIT=$?
        if [[ $DESIGN_LINT_EXIT -ne 0 ]]; then
            echo "ERROR: design-md-lint.sh reported violations in worktree $WORKTREE_PATH (exit $DESIGN_LINT_EXIT)." >&2
            echo "  Resolve design-system violations before commit, or use /dso:fp-recovery if this is a false positive." >&2
            if [[ -n "${TICKET_ID:-}" ]]; then
                .claude/scripts/dso ticket comment "$TICKET_ID" \
                    "CHECKPOINT: design-md-lint.sh blocked commit — violations found in: $DESIGN_LINT_FILES. Fix violations or use /dso:fp-recovery for false positives." 2>/dev/null || true
            fi
            exit 1
        fi
    else
        echo "Step 3.6: no scope-eligible files changed in $WORKTREE_PATH — skipping design-md lint."
    fi
else
    echo "Step 3.6: design.lint_enabled=never — skipping design-md lint."
fi
```

When `design.lint_enabled=auto` (the default), the lint step runs whenever scope-eligible files are present in the diff. When `design.lint_enabled=always`, same behavior (the script itself enforces always-on semantics regardless of auto-detection). When `design.lint_enabled=never`, skip entirely. On violations, add a CHECKPOINT comment and halt — do NOT proceed to Step 4.

**Step 3.7 — Cleanup recipes (Post-Agent, Pre-Commit)**: Runs in the **worktree** context (all Bash calls prefixed with `cd $WORKTREE_PATH &&`), where the sub-agent's `git add -A` (task-execution.md Step 8b) has populated the worktree's staged set. This is the worktree-isolation-mode home of the sprint "Cleanup Recipe Phase" — the orchestrator-body copy operates on the session worktree's (empty) staged set and is skipped in this mode.

```bash
RECIPE_REGISTRY_PATH="${CLAUDE_PLUGIN_ROOT}/recipes/recipe-registry.yaml"
CLEANUP_RECIPES="$(cd "$WORKTREE_PATH" && RECIPE_REGISTRY_PATH="$RECIPE_REGISTRY_PATH" bash "${CLAUDE_PLUGIN_ROOT}/scripts/sprint/detect-cleanup-recipes.sh" 2>/dev/null || true)"
```

If `CLEANUP_RECIPES` is empty, skip this step (no applicable recipes). Otherwise, for each recipe: capture `PRE_CLEANUP_DIFF="$(cd "$WORKTREE_PATH" && git diff --staged)"`, run `cd "$WORKTREE_PATH" && bash "${CLAUDE_PLUGIN_ROOT}/scripts/recipe-executor.sh" <recipe_name> --param language=<lang>`, and if the recipe reverted the sub-agent's staged changes, log a WARNING and skip that recipe for those files. Record a distinct `CLEANUP_DIFF:` ticket comment so reviewers/completion-verifier see the post-cleanup state. The recipe re-stages its output, so the subsequent Step 4 commit captures the cleaned diff.

**Step 4 — Commit in worktree branch**: Execute COMMIT-WORKFLOW.md from the worktree context (all Bash calls prefixed with `cd $WORKTREE_PATH &&`). The commit happens in the worktree's branch (not the session branch). Review gate passes because review-status and diff_hash are in `$WORKTREE_ARTIFACTS`.

**Post-commit verification (mandatory — 1eda-6a0c)**: After the commit workflow, verify the branch tip actually advanced before proceeding to harvest:

```bash
WORKTREE_TIP_AFTER=$(cd "$WORKTREE_PATH" && git rev-parse HEAD 2>/dev/null || echo "")
if [[ "$WORKTREE_TIP_AFTER" == "$WORKTREE_BASE_COMMIT" ]]; then
    echo "ERROR: commit failed — branch tip unchanged after commit attempt (pre-commit gate likely blocked it)." >&2
    echo "  Base: $WORKTREE_BASE_COMMIT" >&2
    echo "  Check the commit output above for TIER IMMUTABILITY VIOLATION or review gate errors." >&2
    # DO NOT proceed to harvest — the worktree is empty and harvest would false-positive as "already merged".
    # Transition ticket back to open for re-investigation.
    exit 1
fi
```

If this check fails: do NOT call harvest-worktree.sh. Leave the worktree intact, add a CHECKPOINT comment to the ticket, and surface the commit gate error to the orchestrator for investigation.

**Step 4a — Visual Evaluator Inline — Integration A (config-gated)**: Runs only when `visual_evaluator.enabled=true` AND `visual_evaluator.integration_a_enabled=true` (both default false). Evaluates committed, reviewed code before harvest.

```bash
TASK_FILE_LIST=$(cd "$WORKTREE_PATH" && git diff --name-only "$WORKTREE_BASE_COMMIT"..HEAD)
if [[ -n "$TASK_FILE_LIST" ]]; then
  cd "$WORKTREE_PATH" && bash "${CLAUDE_PLUGIN_ROOT}/scripts/sprint/visual-eval-inline.sh" "$TASK_FILE_LIST" "$TICKET_ID"  # shim-exempt: internal orchestration script
  VISUAL_EVAL_EXIT=$?
  if [[ $VISUAL_EVAL_EXIT -ne 0 ]]; then
    # intent_match below threshold — do NOT harvest; revert task to open
    echo "Visual eval failed for $TICKET_ID — intent_match below threshold after iteration cap." >&2
    .claude/scripts/dso ticket transition "$TICKET_ID" in_progress open 2>/dev/null || true
    .claude/scripts/dso ticket comment "$TICKET_ID" "CHECKPOINT: Visual evaluation failed — intent_match below iteration_threshold after iteration_cap exhausted. Task reverted to open." 2>/dev/null || true
    continue  # skip to next worktree
  fi
fi
```

When `visual_evaluator.enabled` or `integration_a_enabled` is false, `visual-eval-inline.sh` exits 0 immediately — zero overhead. Check stderr for `visual_eval_routing:<class>:<confidence>` annotations and `visual_debt:<dimension>` tags.

**Step 5 — Harvest worktree into session branch**: From the session branch directory, run `harvest-worktree.sh` to merge the worktree branch, attest gate results, and commit in a single invocation:

```bash
.claude/scripts/dso harvest-worktree <worktree-branch> "$WORKTREE_ARTIFACTS"
```

`harvest-worktree.sh` performs the following sequence atomically:
1. Verifies the worktree's `test-gate-status` and `review-status` exist and are passing (exits 2 if not).
2. Merges `<worktree-branch>` into the current session branch with `--no-commit` (exits 1 on non-`.test-index` conflicts).
3. Calls `record-test-status.sh --attest <worktree-artifacts-dir>` to write session-side `test-gate-status` with the post-merge diff hash and attested `tested_files` from the worktree.
4. Calls `record-review.sh --attest <worktree-artifacts-dir>` to write session-side `review-status` with the post-merge diff hash and attested score/review_hash from the worktree.
5. Commits the merge. Pre-commit hooks pass because the attested status files match the post-merge diff hash.

The `.test-index` file uses a `merge=union` driver (configured in `.gitattributes`), so concurrent additions from multiple worktrees auto-resolve without conflicts.

**Step 6 — Handle harvest result**:
- **Success** (exit 0): Proceed to Step 7 (cleanup).
- **Gate failure** (exit 2): The worktree's test or review gate did not pass. Do NOT merge. Investigate and re-run gates in the worktree context (Steps 2–4), then retry Step 5.
- **Conflict** (exit 1): Non-`.test-index` merge conflict detected. `harvest-worktree.sh` automatically aborts the merge and cleans up MERGE_HEAD.

  > **Why this happens with parallel dispatch**: When multiple sub-agents are dispatched in the same batch, every worktree branches from the session HEAD at dispatch time. As earlier worktrees are harvested serially, the session HEAD advances. Later worktrees are now stale — they are missing the commits from the earlier harvests — and `git merge --no-commit` conflicts on lines that were already modified by a prior harvest. This is **expected and normal**, not a task implementation failure.

  Resolution path — try in order before falling through to full re-implementation:
  1. **Rebase the worktree branch onto the updated session HEAD** (from the session root):
     ```bash
     git -C "$WORKTREE_PATH" rebase <session-branch>
     ```
     If the rebase succeeds cleanly (no conflicts), the worktree's changes are now layered on top of the earlier harvests. Re-run the review → commit → harvest pipeline (Steps 2–5) against the rebased branch. This is sufficient for the common case where the conflicts are purely due to ordering.
  2. **Manual conflict resolution**: If the rebase produces true conflicts (the same lines changed by two different tasks for different reasons), resolve them in the worktree, then continue the rebase (`git rebase --continue`) and re-run Steps 2–5.
  3. **Full task re-implementation** (last resort — see conflict queue below): Use only when the conflict cannot be resolved by rebase (e.g., the task's entire approach is incompatible with what was already merged).

  Regardless of which resolution path applies:
  a. Create a ticket comment: `.claude/scripts/dso ticket comment <story-id> "CONFLICT: worktree <worktree-name> blocked — attempting rebase resolution"`
  b. Add the worktree to the **conflict queue** — do NOT remove the worktree (retained for resolution).
  c. Continue processing the next worktree — non-conflicting worktrees proceed normally through Steps 2–7.
  d. After recording the conflict, write a WORKTREE_TRACKING:complete signal to mark the worktree as discarded (written now; a successful rebase+harvest later does NOT update this signal — the tracking comment records the initial outcome):
     ```
     .claude/scripts/dso ticket comment $TICKET_ID "WORKTREE_TRACKING:complete branch=<branch> outcome=discarded timestamp=<ts>"
     ```
     (Only when TICKET_ID is available from the sprint context. Skip silently if not set.)

- **Empty branch** (exit 3): Branch tip equals the recorded base commit — the agent's `git commit` was blocked by a pre-commit gate (e.g., TIER IMMUTABILITY VIOLATION), or the agent staged changes (`git add -A` per task-execution.md Step 8b) but the orchestrator's Step 4 commit was blocked. No data is at risk — the branch has no commits beyond the base, so nothing is lost by cleanup. Add a CHECKPOINT comment surfacing the gate error, then proceed to Step 7 (cleanup). The task is reverted to open by the sprint orchestrator (Phase F Step 16) and re-dispatched in the next batch with a fresh worktree.

**Conflict queue — resolution protocol** (after all non-conflicting worktrees are merged):

For each worktree in the conflict queue, serialized one at a time against the latest session state:
1. **Attempt rebase resolution first** (covers the common parallel-dispatch ordering case):
   ```bash
   git -C "$WORKTREE_PATH" rebase <session-branch>
   ```
   On clean rebase: proceed directly to Steps 2–5 (review → commit → harvest) in the rebased worktree. No re-implementation needed.
2. **On rebase conflict**: Resolve the conflicting hunks in the worktree, `git rebase --continue`, then proceed to Steps 2–5.
3. **Full re-implementation** (only when rebase is structurally incompatible): Re-dispatch the original task in the conflicting worktree context. Each re-implementation targets the post-merge session branch (so it incorporates all previously merged worktrees). After successful re-implementation: follow the full Steps 2–7 flow.
4. If re-implementation also conflicts: escalate to the user — do not re-queue indefinitely.

**Step 7 — Worktree cleanup**: Run after harvest exit 0 (success / already-merged) OR exit 3 (empty branch). Both are safe-to-clean: exit 0 means changes are integrated; exit 3 means no commits exist beyond the base (nothing to lose). Do NOT run after exit 1 (conflict — retained for resolution) or exit 2 (gate failure — retained for re-investigation).

```bash
git worktree remove --force <worktree-path>
git branch -D <worktree-branch>
```

Both commands run from the session branch directory (not inside the worktree). `<worktree-path>` is the `WORKTREE_PATH` from Step 1. `<worktree-branch>` is the branch name used in the worktree (visible in `git worktree list` or the Agent tool result). Use `git branch -D` (force delete) unconditionally — exit 0 already integrated the changes, and exit 3 has no unique commits to preserve.

**907d cleanup**: When the 907d check in Step 1a detects a reaped worktree (directory gone), the worktree branch may still exist as a dangling ref. After logging the 907d error, delete the orphaned branch:

```bash
git branch -D <worktree-branch> 2>/dev/null || true
```

This prevents accumulation of orphaned branches from reaped worktrees across sprint batches.

**Worktree Retention Protocol**: Do NOT remove a worktree until its harvest is complete. Worktrees with conflicts are retained for re-implementation (Step 6). Race condition guard: the worktree must be held open until harvest. Claude Code's `isolation: "worktree"` cleanup uses an uncommitted-changes retention signal — empirically this is necessary but not sufficient (the harness exposes `worktree_kept_dirty / worktree_kept_branch_mismatch / worktree_kept_remove_failed` discriminators per binary inspection of v2.1.150). A sub-agent that self-commits leaves the working tree clean, falling through to harness removal before the orchestrator's harvest. **Defense: the 907d post-return existence check above must run before any `cd "$WORKTREE_PATH"`** — it converts the otherwise-silent data-loss failure into a loud halt. Agents dispatched under this protocol are bound by `worktree-dispatch.md`'s No-Commit Constraint to avoid the trigger entirely.

**Important**: merge-to-main.sh runs ONCE at session end (Phase I), not per worktree merge. Each per-worktree harvest is worktree-branch → session-branch only.
