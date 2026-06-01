# Session Residual Work — Handoff

**Date**: 2026-05-31
**Source session**: extended workflow-stability investigation (~1M context across ~150 turns)
**Purpose**: capture work surfaced during the session that did not ship and should be considered separately from the workflow-stability plan (see `workflow-stability-plan-v3-handoff.md` for that work).

## In-flight PRs at session end

| PR | Title | State | Notes |
|---|---|---|---|
| **#509** | staged: TMPDIR isolation + bridge-import test fixes → main | OPEN/BLOCKED | Cycle-2 review surfaced regex + jira-api findings. PR #511 fixes the regex; jira-api finding is a stale-context FP. Awaiting cycle-3 to confirm. |
| **#511** | fix(PR 509 cycle-2): tighten from-import regex | OPEN | Sub-PR into staged-b329b49acf0d-1780175275 (PR 509's staged ref). Running CI. |

Next action: monitor PR #511 to CLEAN, merge into staged ref. PR #509 will re-run; if cycle-3 review accepts the regex fix and stops re-flagging jira-api as a stale FP, merge PR 509. If jira-api re-flags, run `/dso:fp-recovery 509` (or use the web-UI bypass once Story 3 lands).

## Deferred work from earlier audit / planning streams

### From the 5/29 DSO Review (not addressed)

The 5_29 audit identified 6 findings; current session addressed Finding 1 partially and Finding 6 partially. Remaining:

- **Finding 1 (Canonical sub-PR enforcement contract)** — `provision-ruleset.sh` rewrite, `check-ruleset-preflight.sh` + test fixture regeneration, `INSTALL.md` updates, CI round-trip test. The current workflow-stability plan addresses parts of this (Story 1 provisioning + Story 3 invariant), but the broader contract reconciliation (5 inconsistent representations of how sub-PR review is enforced) remains scoped as a separate epic.
- **Finding 3 (Load-bearing enforcement hooks fail open)** — `run-hook.sh` fail-open contracts on syntax errors / missing files / per-function ERR traps. Six guards are load-bearing: `hook_test_failure_guard`, `hook_review_bypass_sentinel`, `hook_review_integrity_guard`, `hook_blocked_test_command`, `hook_tickets_tracker_bash_guard`, `hook_no_force_merge`. Requires explicit USER approval per `rule:no-safeguard-edits`. Shadow-mode rollout recommended.
- **Finding 4 (Bash JSON parsing fragility)** — `lib/deps.sh:32-87 parse_json_field` is a pure-Bash parser; should be replaced with `json.loads` via a small `hook_input.py` helper for enforcement hooks. Same approval gate as Finding 3.
- **Finding 6 (TMPDIR test-isolation coverage hole)** — The static check (`check-mktemp-tmpdir.sh`) has a glob gap: `^tests/(.*/)?test-[^/]*\.sh$` is hyphen-only and misses underscore-named files. PR 491 / PR 509 fixed ~20 violations in `test_*.sh` files but the linter still wouldn't catch new ones. Broaden the glob to `^tests/(.*/)?(test[-_][^/]*|run|setup)\.sh$` or scan all `tests/**/*.sh` with an internal allowlist. Run the static check in CI always-on, not changed-files-only.

### From earlier session (PR 482 and prior)

- **PR-R3 (G2 OVER_BOUND fails CI)** — already addressed in main per session check; confirmed by code reading. No action required.
- **Drift-detection tracking ticket (df90-8e29-d734-49ec)** — provisioner-vs-live drift. Filed during session; closed as covered by Story 1 of the v3 plan.

### Hook-enforcement hardening (PR 507's scope, partial)

PR 507 shipped sentinel fail-closed + integrity check. Related items NOT in that PR:
- `hook_input.py` JSON helper (5_29 Finding 4)
- Declarative enforcement-vs-advisory policy map (5_29 Finding 3)
- Auditable, time-scoped recovery bypass (5_29 Finding 3)
- Shadow-mode rollout instrumentation

### Cleanup tasks

- **Worktree cleanup**: Multiple session-spawned worktrees remain under the worktrees root (`<repo>-worktrees/`). Audit + delete after current work concludes:
  - `wt-bug4a30/` — used for bug 4a30 implementation
  - `wt-g2-nits/` — used for PR 490 nits
  - `wt-docs/` — used for docs PR (PR 502)
  - `wt-pr509/` — used for PR 510
  - `wt-pr509-r2/` — used for PR 511
- **Stranded ref audit**: 4 orphan staged refs were found during session; 3 cleaned up (deleted). One remains:
  - `staged-b329b49acf0d-1780175275` (PR 509's staged ref) — will clean up after 509 merges
- **Handoff doc reconciliation** — covered in workflow-stability plan v3 Phase 0; mentioned here for cross-reference. Files to add HISTORICAL header + move to `docs/handoff/archive/`:
  - `docs/handoff/llm-review-pipeline-hardening-handoff.md` (F5 claim is stale)
  - `docs/handoff/llm-review-enforcement-handoff.md` (PR-5 has already landed per live state)

### Observability roadmap (deferred from Story 5)

The workflow-stability plan v3 carries a "Story 5 MINIMUM" scope (structured logs + nightly sweep). The full observability vision deferred for a follow-up epic:
- Defense-accumulation-per-week reporter (suppression-accumulation anti-pattern detector)
- FP-rate signal on review-sub-pr (defenses-per-cycle rolling average)
- Centralized dashboard or metrics endpoint
- Alert thresholds + on-call rotation (out of scope for this codebase's small operator footprint, but worth considering if FP rate becomes a real problem)

### Naming / script refactor (deferred discussion)

Surfaced during session: `merge-to-main.sh` / `merge-to-main-pr.sh` / `merge-to-main-direct.sh` names are misleading under the two-tier model (a single invocation doesn't merge to main — it creates a sub-PR). Discussed renaming candidates:
- `promote-to-main.sh` / `ship-to-main.sh` / `promote-via-pr.sh`

Cost analysis: many doc references, hook scripts grepping the literal command name, test scripts, git-history searchability for bug 5ff0. Decision: defer until after workflow stability lands. The naming pain is real but lower-priority than the architectural fixes.

## Open architectural questions for future consideration

1. **FP-recovery threshold calibration**: current `≥5 tool calls, ≥30s runtime` thresholds (from PR 498/503) are based on a single observation. After Story 2 lands, we'll have more data — should we re-calibrate based on observed defense-review distributions?

2. **Defense store load model**: `review-github-defense-store.sh` reads PR comments via gh API; this scales linearly with PR comment count. For PRs with many cycles, load time is non-trivial. Consider caching strategy.

3. **Integration LLM review FP-rate threshold for Story 4 toggle**: the toggle exists but the trigger for flipping it is undefined. Need empirical data over 30-60 days to set the threshold.

4. **`verification_evidence` schema field on CI path**: dispatch-split shipped (bug 4a30) but the `verification_evidence: {command, output}` field semantics for CI agents (which have no shell) is unresolved. Currently: CI agent emits context-request grep → dispatcher returns output → model copies into finding. This works but isn't ergonomic. Possible future: the dispatcher could synthesize the `verification_evidence.command` field server-side based on the context-request the model emitted.

5. **Multi-agent review (Anthropic's pattern)**: prior-art research surfaced that Anthropic's own code review uses multi-agent verification (multiple independent reviewers cross-checking). We don't do this — single agent per finding. Worth evaluating after FP-rate measurement.

## What to do in the next session

If continuing the workflow-stability work: load `workflow-stability-plan-v3-handoff.md` and execute Phase 0 first.

If addressing residual session work: triage by priority:
1. Finish PR 509 (PR 511 → merge → PR 509 → merge to main)
2. Audit + clean up worktrees + stranded refs
3. File tickets for the deferred 5_29 findings (Finding 1 epic, Findings 3+4 epic with safeguard-edit approval requested, Finding 6 small follow-up)
4. (Optional) reopen the merge-to-main rename discussion

## Cross-references

- **Workflow stability plan v3**: `docs/handoff/workflow-stability-plan-v3-handoff.md`
- **Stale prior handoffs** (move to archive in Phase 0):
  - `docs/handoff/llm-review-pipeline-hardening-handoff.md`
  - `docs/handoff/llm-review-enforcement-handoff.md`
- **External review assessment**: `docs/findings/2026-05-30-external-review-assessment.md` (the 5_29 audit)
