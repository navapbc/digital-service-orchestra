# Workflow-Stability Hardening (v4)

A set of changes that close the chronic-instability and Goal-1 / Goal-4 holes documented in `docs/handoff/workflow-stability-plan-v4-handoff.md`. Two behaviors (net-diff integration review, provenance candidate scoping) are **live** in the pipeline; the new **checks** ship in `warn`/advisory mode and become required via a documented admin go-live step. This doc is the map; see `CI-INTEGRATION.md` for the surrounding integration-review architecture.

## Mechanisms

| Concern | Mechanism | Status |
|---|---|---|
| **Chronic integration re-flag** (an introduce-then-fix pair flagged at its intermediate state; CS-10 / PR #509) | `lib/build-integration-diff.sh` builds the **net end-state** diff `git diff origin/main...HEAD -- <files touched by unprovenanced commits>` instead of concatenating per-commit `git show`. Wired into `llm-review-dispatch-or-skip.sh`. An introduce-then-fix within the range collapses to its final state. | live |
| **Goal-1 laundering** (reachable-from-origin/main treated as "reviewed"; P9) | `scripts/ci/review-coverage-invariant.sh` resolves the FULL `origin/main..HEAD` set with **no reachability prefilter** and requires each SHA to be PROVEN reviewed — a passing (poison-on-failure) review check-run on a covering merged PR (`lib/review-coverage-lib.sh`) — or a hit in the durable reviewed-SHA ledger. **Fails closed** on any API error / not_found / shallow / ambiguity. `assert-review-liveness.sh` additionally rejects the `all_scope_already_merged` laundering skip stub. | check, `warn` rollout |
| **Cross-sub-PR semantic conflict** (P2) | `scripts/ci/check-dangling-references.sh` finds symbols defined at the base in touched files, gone at HEAD (removed/renamed) and not defined elsewhere, then greps the whole repo at HEAD for surviving references — catching cross-module renames and pre-existing untouched callers a diff-scoped review cannot see. | check, `warn` rollout |
| **Shared review-skip blind spot** | `scripts/ci/check-allowlist-correctness.sh` independently validates `review-gate-allowlist.conf` — it must never match code or critical-must-review files, nor contain a catch-all. Runs in the Script Tests gate. | live (test gate) |
| **Review oscillation / non-determinism** | `scripts/ci/review-convergence-check.sh` + `lib/review-finding-identity.sh` (a pr_number-free, content-based finding identity over cited lines) maintain a durable per-cycle history (also the covered-credit ledger) and STALL when a finding is flagged → cleared → re-flagged, or the cycle cap is exceeded. | wired-ready (env-driven) |
| **Post-hoc bypass audit** (Goal-6b) | `scripts/ci/fp-recovery-audit-sweep.sh` emits HMAC-signed markers for merged `main` PRs lacking a passing review check, so a web-UI bypass cannot silently leave the audit trail. | manual / scheduled |
| **Config drift** | `provision-ruleset.sh` emits config matching live; `tests/scripts/test-ruleset-provisioner-roundtrip.sh` (run by `ruleset-invariants.yml`) drift-locks `provisioner == required-checks.txt == live`. | live + enforcing |

## Admin go-live for the `warn`-mode checks

Each new-check workflow runs advisory until an admin promotes it:

1. Flip the workflow's `DSO_*_MODE` env (e.g. `DSO_COVERAGE_INVARIANT_MODE`, `DSO_DANGLING_MODE`) to `enforce`.
2. Add the check's job name (e.g. `review-coverage-invariant`, `dangling-references`) to `.github/required-checks.txt`.
3. Provision it into the live MAIN ruleset (needs an admin token). The round-trip drift test then keeps `required-checks.txt == live` in sync going forward.

Until steps 2–3, a failing check is visible but non-blocking.

## Goal-4 containment (identity-based)

`bypass_mode: pull_request` does NOT restrict the merge *tool* — an admin/bypass actor can merge a failing PR via the REST API — so containment is achieved by IDENTITY: the dev agent runs under a token that is **not** a bypass actor (`current_user_can_bypass: never` on both rulesets), and the sole override is a named human via the GitHub web UI. The bypass actor is a named `User` (config `ruleset.bypass_user_id`), not `RepositoryRole:admin`. `merge-to-main*.sh` route through the staged-PR flow under the non-admin identity and use no admin override. Setup (including the CS-7a credential-helper hygiene that probes both `gh` and `git`): `INSTALL.md` → *Goal-4 containment*.
