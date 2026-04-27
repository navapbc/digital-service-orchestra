# New Epics — 2026-04-26

## Source

Mitigations from `docs/proposed-mitigations-4-26.md` that did not fit any existing open epic. Items absorbed by existing epics are not listed here — see `docs/scope-allocation-4-26.md` (or the per-epic comments added 2026-04-26) for that mapping.

## Design principle

Each cluster below is bounded by a single coherent concern (one enforcement surface, one workflow phase, or one mechanism class). Clusters are sized so each can be delivered as one decomposable epic — between ~3 and ~6 stories — without spanning unrelated infrastructure.

Every cluster uses the **descriptive-first / baselined ratchet** pattern where applicable: a new pre-commit hook ships with a baseline file enumerating existing violations so rollout is non-blocking; the registry is append-only and prevents new violations from regressing. This pattern is already established by precedent (the 26-file SIGPIPE remediation series, ticket `e241-41b2`).

---

## New Epic A — Static-analysis defense layer for hermeticity, antipatterns, and config drift

### Problem
Pre-commit hooks today are syntactic only (paths, schemas, ticket IDs, executable bits). Several recurring failure classes — `$CLAUDE_PLUGIN_ROOT` unbound under `set -u`, SIGPIPE on `… | grep -q` under `pipefail`, `declare -A` on bash 3.2 targets, config keys without paired documentation — have no static-detection gate. The release gate (`validate.sh --ci`) catches these post-merge; the pre-commit stack admits them.

### Cited evidence
- Pattern 1 (~25% of recent fixes): `fe45-0b58`, `09d8-11f0`, `82ad-7bb3`, `97a7-4504`, `a40e-ab52`
- Pattern 3 (~10%): identical-root-cause regressions across the chain above
- Pattern 4 (~8%): `e241-41b2` (26-file sweep), `999e-cf69` (27th instance)
- Pattern 7: `a190-d780` (`commands.test_dirs` undocumented)

### Mitigations included
- **G1-M1** — `check-hermeticity.sh` pre-commit hook scanning staged `.sh` files for: unguarded `$CLAUDE_PLUGIN_ROOT` references when `set -u` is active; `declare -A` in scripts under platform-matrix-targeted directories; `BASH_SOURCE` resolution that does not flow through `readlink -f` or equivalent.
- **G6-M2** — `check-known-antipatterns.sh` reading regex/AST queries from `plugins/dso/config/known-antipatterns.yaml`; append-only registry.
- **G11-M1** — `check-config-key-docs.sh` cross-referencing `dso-config.conf` keys against `CONFIGURATION-REFERENCE.md`.
- **G12-M1** — `check-pipefail-grep.sh` flagging `echo … | grep -q` under `pipefail`; ships with baseline of existing 42 instances.

### Proposed success criteria
1. Four new pre-commit hooks ship in `.pre-commit-config.yaml`, ordered between `shellcheck` and `pre-commit-review-gate`.
2. Each hook supports a baseline file mechanism so existing violations do not block rollout; new violations are blocked.
3. Hooks emit per-file diagnostics with the exact remediation string and a citation back to the originating ticket (`e241-41b2`, `a190-d780`, etc.).
4. `plugins/dso/config/known-antipatterns.yaml` is created, append-only, and documented in `CONFIGURATION-REFERENCE.md`.
5. Suppression annotations follow the precedent of existing hooks (`# bash4-only:`, `# antipattern-ok: <reason>`); each annotation requires a justification token.
6. Test coverage: each hook has a fixture-based test asserting (a) the antipattern is detected on staged content, (b) baselined existing violations do not fire, (c) new instances of the antipattern are blocked.

### Coordination notes
- Coexists with `cf7b-86a9` (which adds shellcheck/ruff parity) — different layer, different antipattern class.
- Sets up the registry that **New Epic E** (fix-bug recurrence) populates over time.

### Estimated complexity: MODERATE (4 parallel hook implementations + shared baseline plumbing).

---

## New Epic B — Reviewer rubric expansion: platform, runner, hermeticity, config, pipefail dimensions

### Problem
Direct grep of the four reviewer delta prompts (`reviewer-delta-deep-correctness.md`, `reviewer-delta-deep-hygiene.md`, `reviewer-delta-test-quality.md`, `reviewer-delta-deep-verification.md`, plus `reviewer-delta-standard.md`) confirms that `pipefail` is mentioned in passing and `mktemp` appears only as a cleanup pattern. None of the prompts contain `CLAUDE_PLUGIN_ROOT`, `hermetic`, `bash 3`, `declare -A`, `SIGPIPE`, `BASH_SOURCE`, runner-equivalence, or env-var guard items as named checklist entries. Reviewers cannot flag what their rubric does not name.

### Cited evidence
- G4 (rubric coverage gap, all 4 prompts verified)
- Patterns 1, 2, 4 — bug classes that reviewers consistently miss because no rubric item targets them.

### Mitigations included
- **G1-M2** — Hermeticity items in deep-correctness and deep-hygiene (env-var guarding, `set -u` exposure).
- **G2-M3** — Cross-runner change item in standard and deep-correctness (when diff touches `plugins/dso/scripts/runners/`).
- **G4-M1** — Platform-axis sub-section in deep-correctness (env-var guarding, bash-3.2 incompat list, SIGPIPE-safety, BASH_SOURCE resilience).
- **G4-M2** — Cross-platform check in deep-verification (test must run in bash 3.2, clean env, both runners).
- **G11-M3** — Config doc paired-update item in standard.
- **G12-M2** — Pipe-to-grep under pipefail item in deep-correctness.

### Proposed success criteria
1. Six named rubric items are added to the reviewer delta prompts as listed above; each item names the bug class, cites the originating ticket, and specifies a severity floor.
2. A reviewer-prompt regression test asserts each item's heading is present (parallel to the skill-section manifest pattern in `a8e8-0b23`).
3. Findings emitted by reviewers under the new rubric items are tagged with the rubric source (e.g., `rubric:platform-axis`) so adoption can be measured via `review-stats.sh`.
4. Documentation: `REVIEW-WORKFLOW.md` is updated to enumerate the new rubric dimensions.

### Coordination notes
- Pure additive change to existing reviewer prompts — does not interact with **New Epic C** (override discipline) which constrains how reviewers *use* findings.
- Uses the new rubric flag injection mechanism added to `ab57-b534` (G4-M3): once `ab57-b534` ships, implementation-plan can inject these flags at task-classification time.

### Estimated complexity: MODERATE (small per-prompt edits but coordination across 5 prompt files + a regression-test harness).

---

## New Epic C — Reviewer override discipline: defense citations, downgrade quorum, isolation-ok registry

### Problem
The REVIEW-DEFENSE protocol (`reviewer-base.md:209-220`) authorizes reviewers to "lower severity or remove finding" when they "agree" with an in-code defense. The acceptance criterion ("verifiable artifacts") is subjective; a single LLM reviewer can self-override without external attestation. Inline `# isolation-ok:` comments (`reviewer-delta-standard.md:35`) operate identically — the reviewer can only check the comment exists, not whether the rationale is valid. This mirrors Pattern 5 (LLM-behavioral self-attestation) at the code level.

### Cited evidence
- G5 (verbatim quotes confirmed)
- Pattern 5 — `3dae-af1a` (open) shows the agent self-attestation failure mode in the orchestrator; `feedback_review_gate_discipline.md` memory entry shows the same risk at review time.

### Mitigations included
- **G5-M1** — `# REVIEW-DEFENSE:` comments require a verifiable citation (path, URL, ticket ID); `check-review-defense-citations.sh` pre-commit hook enforces.
- **G5-M2** — When a reviewer downgrades a finding via REVIEW-DEFENSE, dispatch a second reviewer to independently evaluate without seeing the first verdict; higher severity wins on disagreement.
- **G5-M3** — Replace inline `# isolation-ok:` annotations with a tracked registry (`plugins/dso/config/isolation-exceptions.yaml`) carrying `{file, reason, approved_by, ticket_id, expires_on}`; pre-commit hook validates registry entries are present and unexpired.

### Proposed success criteria
1. `# REVIEW-DEFENSE:` comments lacking a citation token are rejected at pre-commit; comments with citations are unblocked.
2. Reviewer JSON output adds `severity_lowered: bool` and `defense_cited_artifact: string`; when `severity_lowered` is true, REVIEW-WORKFLOW.md dispatches a second reviewer.
3. Inline `# isolation-ok:` annotations are deprecated; a one-time migration converts existing instances to registry entries (one ticket created per migrated entry to assign approver attestation retroactively).
4. Registry entries with `expires_on` in the past block the relevant commit until renewed.
5. `review-stats.sh` reports downgrade rate and defense-citation rate; baseline measured pre-rollout.

### Coordination notes
- Companion to **New Epic B**: B *adds* rubric items so findings are surfaced; C *constrains* how findings are dismissed.
- Interacts with `c183-ed2a` (adversarial review of inference decisions): the second-reviewer pattern in G5-M2 mirrors c183-ed2a's red-team challenge mode but applies to reviewer downgrades rather than orchestrator inferences.

### Estimated complexity: MODERATE-HIGH (touches reviewer dispatch, JSON schema, hook layer, and existing in-code annotations across the tree).

---

## New Epic D — Cross-runner equivalence contract testing

### Problem
Four test runners (`bash-runner.sh`, `suite-engine.sh`, `run-hook-tests.sh`, `validate.sh`) have drifted on RED-marker tolerance, `command_hash` tracking, scope, and timeout budget. Each drift was caught reactively post-merge. Ticket evidence: `7225-7708`, `bf39-4494`, `e2b6-1059`, `e8a9-136f` — four separate fixes for the same class of drift. No process step asserts equivalence.

### Cited evidence
- Pattern 2 (~15% of recent fixes); G2 verified.

### Mitigations included
- **G2-M1** — `tests/runners/test-runner-equivalence.sh` taking a fixed corpus (known-passing, known-RED-marker, known-skipping) and asserting all runners produce the same pass/fail/skip classification per file. Pre-commit hook `runner-touch-check.sh` fires only when the diff touches `plugins/dso/scripts/runners/`.

### Proposed success criteria
1. A fixed corpus exists under `tests/runners/fixtures/` covering the three classification axes; corpus is documented and stable.
2. Equivalence test asserts identical classification across all declared runners; runs in `validate.sh --ci`.
3. Pre-commit hook `runner-touch-check.sh` runs the equivalence test only when the diff touches runner code; failure blocks the commit.
4. New runner additions are detected automatically (the test enumerates runners from a manifest, not a hardcoded list).
5. Each cited drift ticket (`7225-7708`, `bf39-4494`, `e2b6-1059`, `e8a9-136f`) corresponds to a regression case in the corpus.

### Coordination notes
- Pairs with `ab57-b534`'s new sub-criterion (G2-M2 absorbed there): planner mandates a corpus update in any runner-touching task, and this epic delivers the corpus + test that the planner references.

### Estimated complexity: MODERATE (corpus design + test harness + hook).

---

## New Epic E — fix-bug recurrence prevention: tree-wide antipattern scan + hermetic repro

### Problem
Pattern 3 (identical-root-cause regressions, ~10%) is the dominant repeat-bug class. The current `/dso:fix-bug` skill mandates intent-search for the same ticket's history but does not require a tree-wide scan for the same antipattern after the fix. The prior-art protocol (`prior-art-search.md:79-88`) explicitly excludes single-file fixes. Many Pattern 1 bugs were originally reproducible only in CI because the local repro was contaminated by inherited environment.

### Cited evidence
- Pattern 3 chain: `09d8-11f0` → `fe45-0b58` → `82ad-7bb3` → `97a7-4504` (4 tickets, identical root cause)
- Pattern 1: every cited ticket originally lacked a hermetic repro until the CI failure surfaced it.
- G6 (prior-art exclusion verified at `prior-art-search.md:79-88`); G9 (fix-bug hermetic repro absent).

### Mitigations included
- **G6-M1** — `/dso:fix-bug` mandatory post-fix step: extract the antipattern as a regex or `sg` AST query; run tree-wide; for matches outside the fixed file, either include in scope, file follow-up tickets, or annotate with `# antipattern-ok:`. Commit message records the query and match count.
- **G9-M3** — `/dso:fix-bug` Step 5 requires the RED test be reproducible in `env -i bash -c 'unset CLAUDE_PLUGIN_ROOT; <test command>'`. Non-hermetic RED tests are reframed as environmental noise.

### Proposed success criteria
1. `/dso:fix-bug` SKILL.md adds a post-fix Step 7.5 (after fix verification, before commit) that documents the antipattern scan procedure with exact `sg` and `grep` invocations.
2. Commit messages from `/dso:fix-bug` include an `Antipattern-Scan: <query> matches=<n>` trailer; `/dso:commit` workflow reads the trailer and refuses to commit a fix-bug change without it (or with `matches > 0` and no follow-up plan).
3. `/dso:fix-bug` Step 5 enforces hermetic-repro check; non-hermetic RED tests block progression to Step 6.
4. The known-antipatterns registry (delivered by **New Epic A**) is the receiving home for queries surfaced by Step 7.5; this epic adds a one-line "promote to registry" sub-step.
5. Coverage: re-running the procedure against the cited Pattern 3 chain (`09d8-11f0` → `fe45-0b58` → ...) would have collapsed the chain into a single fix; documented as a regression scenario.

### Coordination notes
- Hard dependency on **New Epic A** for the antipattern registry (G6-M2). Sequence: A ships the registry; E populates it.

### Estimated complexity: MODERATE (focused fix-bug workflow additions + commit-trailer plumbing).

---

## New Epic F — CI health enforcement and release-gate streak requirement

### Problem
`ticket-platform-matrix.yml` has failed 7 of 7 recent runs on `main` (100%); `ticket-perf-regression.yml` has failed 5 of 5 (100%). No open ticket tracks either as an outage. Persistent CI red has been silently tolerated. Separately, `scripts/release.sh` precondition #8 (`validate.sh --ci`) is the de facto integration test — 16 of 22 recent closed bugs were caught here, days after the regressions landed.

### Cited evidence
- G7 (release-gate as integration test verified)
- G8 (workflow failure rates verified via `gh run list`)

### Mitigations included
- **G7-M1** — Post-commit hook (or `.git/hooks/post-commit`) triggers `validate.sh --ci` in the background after every commit on a worktree branch; results piped to a notification channel (terminal banner, log file). Non-blocking; alerts the orchestrator at next interaction.
- **G8-M1** — File two P1 tickets immediately for the persistent-red workflows (one per workflow, tagged `ci-infrastructure`). Add to `CLAUDE.md` "Always Do These": *"When a CI workflow fails 3+ consecutive times on `main`, file a P1 ticket within 24 hours. Persistent CI red is treated as an outage, not a known-issue."*
- **G8-M2** — Extend `scripts/release.sh` precondition checklist to require, for each workflow declared in `release-required-workflows.yaml`, that the last 3 runs on `main` are all green. A single passing run after a red streak is not sufficient.

### Proposed success criteria
1. Two P1 tickets exist tagged `ci-infrastructure` referencing the failure logs of `ticket-platform-matrix.yml` and `ticket-perf-regression.yml`.
2. CLAUDE.md "Always Do These" is amended with the 3+ consecutive failure rule, citing the empirical context.
3. `release-required-workflows.yaml` is created at the repo root listing the workflows whose health blocks release.
4. `scripts/release.sh` precondition #8 is extended (or a new precondition added) requiring last-3-green per declared workflow; release aborts on any red within the window.
5. Post-commit hook is opt-in via `dso-config.conf` (`background_validate.enabled`, default false); when enabled, surface results via the existing notification channel without blocking the commit.
6. The `ticket-platform-matrix.yml` and `ticket-perf-regression.yml` failures are diagnosed and resolved as part of this epic's scope (the P1 tickets in SC1 are children of this epic, not separate work).

### Coordination notes
- Pairs with the items absorbed by `cf7b-86a9` (G1-M3, G9-M1, G9-M2) and `3aaa-0238` (G7-M3, G8-M3, G12-M3): collectively the four epics close the local-vs-CI parity gap.
- The release-streak requirement (G8-M2) is upstream-compatible with `1083-fb3d`'s PR-based merge model — once PRs are mandatory, the streak check applies to PR-required workflows.

### Estimated complexity: MODERATE-HIGH (CI investigation work for SC6 has unknown depth + release.sh changes affect a sensitive script).

---

## Cross-epic ordering

| Sequence | Rationale |
|---|---|
| **A → E** | E populates the registry that A creates; A must ship first. |
| **B ↔ C** independent | Additive vs restrictive; can ship in either order or in parallel. |
| **D** independent | Standalone test infrastructure; no hard dependency. |
| **F** independent | CI/release surface; can proceed in parallel with all others. |
| **B coordinates with** `ab57-b534` | `ab57-b534` adds reviewer flag injection (G4-M3); B's rubric items become injection targets. Soft dependency. |

## Total mitigations covered by new epics

19 of 36 (the SEPARATE bucket from the scope categorization). The remaining 17 are absorbed by existing epics per `docs/scope-allocation-4-26.md` (or per the per-epic scope-expansion comments added 2026-04-26).
