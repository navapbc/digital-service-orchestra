# Workflow-Stability Execution Log — 2026-06-01

**Continues**: `workflow-stability-plan-v4-handoff.md` (THE plan) and
`2026-05-31-workflow-stability-session-log.md` (prior session — live GitHub changes).
**Branch**: `feat/ruleset-bypass-actor-f008cfb359` (cut from `origin/main`, carries the
prior session's commit `f008cfb359` cherry-picked; the original `worktree-20260528-085216`
branch had an already-merged PR and could not be pushed). **Commits this session are local —
NOT merged.** `merge-to-main.sh` is intentionally deferred to the final E2E (per the plan).

## Live baseline re-verified (Step 2 — all green, no drift)
- gh identity `joeoakhart`, `site_admin=false`; repo perms `admin=false, maintain=true, push=true` (non-admin).
- MAIN ruleset 15629023 + SUB-PR ruleset 16961402: `current_user_can_bypass = never` (containment intact).
- `bypass_actors` introspection empty (admin-read-only — expected; outcome-based `never` is the load-bearing control, CS-19).
- `ruleset-design-invariants` present in MAIN required checks → drift detection enforcing.
- `DSO_RULESETS_READ_TOKEN` secret exists (set 2026-06-01T03:12:27Z).
- `git credential fill` for github.com → `joeoakhart`, `admin=false` (no admin token reachable by git); gh git-credential helper wired at github.com scope.

## Implemented + committed this session
1. **W1 remainder** — `2fe97cdf47`. `provision-ruleset.sh` sub-PR rule fixed to
   `required_status_checks{review-sub-pr, do_not_enforce_on_create=true}` + `copilot_code_review`
   (matches live; CS-2 closed); dangling `review-sub-pr.yml` binding + unused `REPO_ID` removed.
   New round-trip drift test `test-ruleset-provisioner-roundtrip.sh` (8/8 incl. live R7/R8),
   wired into `ruleset-invariants.yml`. `required-checks.txt` stale comment fixed.
2. **W2a + W2d** — `fee6935efb`. New `lib/build-integration-diff.sh::build_net_integration_diff`
   (net-end-state `git diff origin/main...HEAD -- <touched files>`), wired into
   `llm-review-dispatch-or-skip.sh` replacing the per-commit `git show` concat (CS-10). New test
   `test-build-integration-diff.sh` reproduces P5 (7/7); dispatcher test updated to reachable
   fixtures (42/42). The chronic re-flag (the #509 class) is fixed.

## Verified green (regression)
- `test-ruleset-provisioner-roundtrip.sh` 8/8 (live) · `test-ruleset-design-invariants.sh` 9/9 (live)
- `test-build-integration-diff.sh` 7/7 · `test-llm-review-dispatch-or-skip.sh` 42/42
- shellcheck clean on all changed scripts.

## Known pre-existing failures (NOT regressions — tracked)
- `tests/workflows/test-integration-review-skip-on-provenance.sh` 6/7 fail (verify-session-provenance.sh
  all-provenanced fixture). Confirmed identical on the pre-W2 dispatcher. Ticket **sip-flume-nog**
  (`ed1e-b88d-0b82-4413`).

## Remaining (see plan §0 PENDING for exact build notes)
- **TS-1** (largest; do not half-build — extract G3 predicate from verify-session-provenance.sh:484-634,
  add reviewed-SHA ledger, new fail-closed `review-coverage-invariant` required check, harden
  assert-review-liveness.sh skip-stub acceptance). Laundering filters to neutralize:
  `llm-review-dispatch-or-skip.sh` `comm -23` + `verify-session-provenance.sh` `^origin/main`.
- **W2b/c** (covered-credit + convergence + CI-side finding-identity hash, no pr_number).
- **W6** (symbol-level dangling-reference check), **W3d** (fp-recovery web-UI + post-hoc audit),
  **W4/W5/W7/W8** (candidate-type, allowlist-correctness, observability, docs + merge-to-main reconciliation).

## FULL PLAN COMPLETED (2026-06-01, second pass — user-approved)

All v4 workstreams are now implemented + TDD-tested + committed on this branch:

| WS | Commit | Summary |
|---|---|---|
| W1 | 2fe97cdf47 | provisioner required_status_checks for sub-PR + round-trip drift lock |
| W2a/d | fee6935efb | net-end-state integration diff (CS-10 fix) + fail-closed |
| W3d (Step 5) | 8f6aa420c7 | fp-recovery web-UI merge link (no agent --admin) |
| TS-1 | d9b2b49225 | fail-closed review-coverage-invariant + ledger + assert-review-liveness hardening (P9) |
| W6 | 2df02aabf3 | symbol-level dangling-reference check (P2) |
| W5 | 63ed3112e5 | independent allowlist-correctness gate |
| W4 | d26810f369 | provenance candidate-type scoping (Gap-2; removed blanket A3a) |
| W7 | 387c844be4 | structured AUDIT decision records per integration-review branch |
| W3d (audit) | 8384faf26c | post-hoc bypass audit sweep + HMAC markers (Goal-6b) |
| W2b/c | 042a6981fc | finding-identity (no pr_number) + convergence/cycle-cap detector |
| W8 | 8468f1c6b3 | WORKFLOW-STABILITY-CHECKS.md + INSTALL Goal-4 containment + CLAUDE pointer |

Test counts: provisioner-roundtrip 8/8 (live), invariant 9/9 (live), build-integration-diff 7/7,
dispatcher 43/43, review-coverage-invariant 9/9, assert-review-liveness 17/17, dangling-references 6/6,
allowlist-correctness 6/6, provenance W4 2/2 (+ contract 20 / cases 15 / no-trailer 5 / main 35),
convergence 7/7, audit-sweep 7/7. shellcheck/actionlint clean throughout.

## REMAINING — admin go-live only (require an admin token; agent is non-admin by design)
Each is an admin action; the code/tests/workflows are all in place:
1. **review-coverage-invariant** (TS-1): flip `DSO_COVERAGE_INVARIANT_MODE=enforce` in the workflow,
   add `review-coverage-invariant` to `.github/required-checks.txt`, provision into the live MAIN ruleset.
2. **dangling-references** (W6): same pattern (`DSO_DANGLING_MODE=enforce` + required-checks + provision).
3. **review-convergence-check** (W2c): wire into `ci.yml` integration-review path (env-driven; not yet invoked).
4. **fp-recovery-audit-sweep** (W3d): set `DSO_AUDIT_HMAC_KEY` secret; optionally schedule the sweep.
The W1 round-trip drift test keeps `required-checks.txt == live` in sync once these land.

## Working-tree note
`plugins/dso/docs/CI-INTEGRATION.md` has an uncommitted linter change (partial `# shim-exempt`
annotations on pre-existing doc-example refs). It is benign and unrelated to the workstreams; left
uncommitted because completing the remaining ~13 prose-line exemptions is out of scope. The new
content lives in `WORKFLOW-STABILITY-CHECKS.md` instead.

## Next session
Continue on `feat/ruleset-bypass-actor-f008cfb359`. Run `merge-to-main.sh` as the final two-tier E2E
(exercises the staged-PR flow + all these changes through CI). The 6 pre-existing
`test-integration-review-skip-on-provenance.sh` failures (ticket sip-flume-nog) are unrelated.
