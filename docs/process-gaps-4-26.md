# Process Gaps — 2026-04-26

## Summary

This report identifies process gaps in the DSO planning, execution, and validation pipelines that map to the eight failure patterns documented in `docs/observed-failure-patterns-4-26.md`. Each gap is cited with file:line evidence and attributed to one or more patterns. Where multiple groupings are plausible, alternatives are noted at the end of each gap.

**Headline conclusions**

- **The validation stack does not enforce hermeticity, cross-runner equivalence, or cross-platform compatibility.** The gates that exist are syntactic (paths, shims, schemas, ticket IDs); none are environmental. Patterns 1, 2, 3, 4, 8 all flow through this gap.
- **Skill prose contains structurally permissive language ("graceful degradation", "skip if") at gate steps.** The codebase has 6+ instances of this language at decision points where the user's intent is mandatory dispatch. Pattern 5.
- **Two CI workflows (`ticket-platform-matrix.yml`, `ticket-perf-regression.yml`) are 100% failing and have been for the entire visible history.** They are exactly the workflows that would catch Patterns 1, 4, and 8. Their persistent red status appears to have desensitized the team — they no longer act as gates.
- **The reviewer rubrics catch logic and test-shape issues but have no items for `CLAUDE_PLUGIN_ROOT` guards, bash version, BASH_SOURCE-through-symlink, or runner-equivalence.** Reviewers cannot flag what their rubric does not name. Patterns 1, 2, 4.
- **Prior-art search explicitly excludes single-file bug fixes** — the exact case where Pattern 3 manifests.

---

## Gap inventory

### G1. No hermeticity gate in the pre-commit stack

**Description:** No pre-commit hook scans for unguarded `$CLAUDE_PLUGIN_ROOT` references, `set -u` violations, `declare -A` usage on scripts that must run on bash 3.2, or `BASH_SOURCE` resolution through pre-commit's symlink chain. Hermeticity is a per-script concern with no project-level invariant.

**Evidence:**
- `.pre-commit-config.yaml` lists 17 hooks: `executable-guard`, `portability-check`, `shim-refs-check`, `contract-schema-check`, `referential-integrity-check`, `test-index-duplicates-check`, `format-and-lint`, `isolation-check`, `pre-commit-test-gate`, `plugin-boundary-check`, `plugin-self-ref-check`, `check-tickets-boundary`, `pre-commit-test-quality-gate`, `enforcement-boundary-check`, `shellcheck`, `pre-commit-review-gate`, `pre-commit-ticket-gate`. **None are environmental.**
- `plugins/dso/scripts/check-portability.sh` — checks for hardcoded `/Users/`, `/home/` paths only, not env-var guards.
- `.claude/hooks/pre-commit/shellcheck.sh:36` — runs `shellcheck --severity=info`. Shellcheck has no rule for `declare -A` on bash-3.2 targets, no rule for `$CLAUDE_PLUGIN_ROOT` guard absence, no rule for SIGPIPE-on-pipefail. CI's leg (`.github/workflows/ci.yml:41`) raises severity to `warning` but the same coverage gap remains.
- `plugins/dso/hooks/check-tickets-boundary.sh` — known instance of the BASH_SOURCE-symlink failure (ticket `a40e-ab52`); no static check exists for the same antipattern in sibling hooks.

**Attribution:** Patterns **1**, **3**, **4**.

**Alternative grouping:** This could be split into G1a (env-var hermeticity) and G1b (bash-version compat) and G1c (BASH_SOURCE/symlink). Combined here because the missing infrastructure (a tree-walking pre-commit gate driven by AST/regex rules) is the same.

---

### G2. No cross-runner equivalence gate

**Description:** Four test runners (`bash-runner.sh`, `suite-engine.sh`, `run-hook-tests.sh`, `validate.sh`) have drifted on RED-marker tolerance, `command_hash` tracking, scope, and timeout budget. No process step asserts they produce equivalent output for the same input.

**Evidence:**
- `plugins/dso/scripts/runners/bash-runner.sh:131-133` (per the audit) — comments acknowledge mirroring `suite-engine` semantics, but the mirror is maintained by hand.
- Tickets `7225-7708` (RED markers in bash-runner missing), `bf39-4494` (validate.sh PENDING loop), `e2b6-1059` (validate.sh scope vs CI), `e8a9-136f` (figma-pullback RED registration) — four separate post-merge fixes for the same class of drift, no convergence test added.
- `plugins/dso/docs/workflows/REVIEW-WORKFLOW.md:54-116` — reviewer Step 1 runs `validate.sh --ci` only; does not also run the suite-engine path or compare outputs.
- `plugins/dso/skills/sprint/SKILL.md` — sprint orchestrator dispatches test execution but has no step asserting "if you touched bash-runner.sh, also run the suite-engine equivalence check."

**Attribution:** Pattern **2**, contributing to **3**.

---

### G3. Skill gates contain structurally permissive language

**Description:** Multiple planning-phase gates use words like "gracefully degrade," "skip if," "if appropriate," or have inline-fallback escape paths that read as opt-out for an LLM agent acting on the prose.

**Evidence (exact quotes / locations from the audit):**
- `plugins/dso/skills/brainstorm/phases/approval-gate.md:4` — "Do NOT present this gate unless ALL of the following have completed **or gracefully degraded with a logged rationale**." Step 2.6 (line 6) and scenario analysis (line 45) reuse the same clause.
- `plugins/dso/skills/preplanning/SKILL.md:357,365` — "Skip this phase if fewer than 3 stories exist" / "If no stories qualify… skip integration research."
- `plugins/dso/skills/preplanning/SKILL.md:380,397` — red-team and blue-team dispatch are MUSTs but with "If agent unavailable: read inline and re-dispatch" fallbacks that lack a check on whether the inline fallback was actually executed.
- `plugins/dso/skills/implementation-plan/SKILL.md:403` — Step 2 architectural review skipped when "no new pattern is proposed."
- `plugins/dso/skills/implementation-plan/SKILL.md:480` — `dso:approach-decision-maker` agent dispatch with "Inline fallback" path.
- `plugins/dso/skills/brainstorm/SKILL.md:441` — complexity-evaluator labelled "safe fallback" if dispatch fails (i.e., the gate degrades silently).
- `plugins/dso/skills/debug-everything/SKILL.md` and `plugins/dso/skills/fix-bug/SKILL.md` — multiple "Graceful degradation: If <X> is missing…" clauses.
- Bug `3dae-af1a` (cited in failure-patterns report) is a confirmed exploitation of exactly this clause: brainstorm agent skipped scrutiny pipeline citing graceful-degradation prose, then applied `brainstorm:complete` tag without dispatching.

**Attribution:** Pattern **5** primarily; contributes to **6** when the skipped step is the dispatch of a sub-agent that would have caught a boundary drift.

**Alternative grouping:** Could be split into G3a (gate language is permissive) and G3b (fallback paths bypass enforcement). Combined here because both let the orchestrator continue without the protective dispatch.

---

### G4. Reviewer rubrics have no item for hermeticity, cross-runner, or cross-platform

**Description:** The deep-correctness, deep-hygiene, deep-verification, test-quality, and standard reviewer rubrics check for `set -euo pipefail` and quoting but contain no items for:
- `$CLAUDE_PLUGIN_ROOT` being explicitly guarded or asserted at script entry
- bash 3.2 compatibility (no `declare -A`, no bash 4+ syntax) on scripts that the platform matrix targets
- BASH_SOURCE-through-symlink resilience under pre-commit
- Test cross-runner coverage (does this test pass under both bash-runner and suite-engine?)
- Test hermeticity (`mktemp HOME`, `unset CLAUDE_PLUGIN_ROOT`, fresh PATH)

**Evidence:**
- `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-correctness.md:109-112` — pipefail check only; no env-var guard check.
- `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-hygiene.md:49-62` — bash hygiene mentions strict mode, not hermeticity or version compat.
- `plugins/dso/docs/workflows/prompts/reviewer-delta-test-quality.md:54-73` — bash test patterns reviewed, no cross-runner equivalence requirement.
- `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-verification.md:54-63` — bash test checklist with assert helpers and traps; no hermeticity item.
- `plugins/dso/skills/shared/prompts/behavioral-testing-standard.md:67-77` — Rule 3 "execute and assert outcome," no requirement to do so under multiple runners or in clean env.

**Attribution:** Patterns **1**, **2**, **4**.

---

### G5. `REVIEW-DEFENSE` and `# isolation-ok:` escape clauses allow subjective override

**Description:** Reviewers are instructed to consider in-code defense comments and to lower or remove findings if they "agree." Severity, by rule, may be lowered without external attestation. This creates a path by which Pattern 5 (skill-level permissiveness) is mirrored at the code level.

**Evidence:**
- `plugins/dso/docs/workflows/prompts/reviewer-base.md:209-220` — REVIEW-DEFENSE protocol: "If you agree: lower severity or remove finding."
- `plugins/dso/docs/workflows/prompts/reviewer-delta-standard.md:35` — `# isolation-ok:` annotation lets a hook script omit isolation; reviewer can only check the comment exists, not whether the rationale is valid.
- CLAUDE.md rule 11 ("Never override reviewer severity") would block the orchestrator from doing this manually, but the mechanism here is the reviewer agent itself self-overriding under the defense protocol.

**Attribution:** Pattern **5**.

**Alternative grouping:** This could be a sub-case of G3 (permissive gate language). Kept distinct because G3 is about skill prose at orchestrator level and G5 is about reviewer-prose at sub-agent level.

---

### G6. Prior-art search explicitly excludes the case where regressions actually happen

**Description:** Pattern 3 (identical-root-cause regressions) is the dominant repeat-bug class — same env-var antipattern in script after script. The prior-art protocol disclaims responsibility for exactly this case.

**Evidence:**
- `plugins/dso/skills/shared/prompts/prior-art-search.md:79-88` — "Routine exclusions: single-file logic fixes, formatting/lint, test reversions, doc-only edits, config value updates." The exclusion text reads: "a change confined to one file that corrects a clear bug without introducing new abstractions does not require a prior-art search."
- `prior-art-search.md:23-27` — trust-validation gate names "open bug tickets on the pattern" and "CI failures on the same files" as blockers, but does not require *codebase-wide grep for the antipattern* before declaring a fix complete.
- Concrete recurrence: `09d8-11f0` (pre-commit-format-fix.sh) → `fe45-0b58` (skip-review-check.sh) → `82ad-7bb3` (bash-runner.sh) → `97a7-4504` (annotation follow-up). Each ticket was treated as a single-file fix and excluded from prior-art search by this rule.
- `plugins/dso/skills/fix-bug/SKILL.md` and `plugins/dso/skills/debug-everything/SKILL.md` — neither mandates a tree-wide scan after a fix lands, only intent-search for the same ticket's history.

**Attribution:** Pattern **3** primarily; contributes to **1** and **4** because both manifest as cross-script repeats.

---

### G7. The release-gate (`validate.sh --ci`) is the de facto integration test; pre-commit gates leak the same regressions repeatedly

**Description:** 16 of the recent 22 closed bugs were detected by `scripts/release.sh` precondition #8 (`validate.sh --ci`) — i.e., post-commit, post-merge, at release time. The pre-commit hook stack admits these regressions because none of G1's checks are present.

**Evidence:**
- Closed-bug discovery channel breakdown (failure-patterns report, Pattern 2 evidence): CI/release gate = 17 of 37; debug-everything = 15; code review = 3; user-flagged = 2.
- `scripts/release.sh` runs `validate.sh --ci` as precondition #8 — confirmed in repo and in failure-patterns report.
- The pre-commit gate stack in G1 evidence above contains no equivalent of `validate.sh --ci`. `pre-commit-test-gate.sh` is per-staged-file, not full-suite.
- Sprint and fix-bug do not require `validate.sh --ci` before commit; they require `record-test-status` for staged files.

**Attribution:** Patterns **1**, **2**, **3**, **4** — each of these patterns has been caught only by the release gate because earlier gates do not check for them.

**Alternative grouping:** Could be reframed as "pre-commit gates have wrong scope (per-file rather than per-suite)." Kept as a single gap because the practical effect is the same: regressions land on `main` and are caught at release time.

---

### G8. Two CI workflows that would catch Patterns 1, 4, and 8 are persistently red

**Description:** `.github/workflows/ticket-platform-matrix.yml` (Linux bash 4 / macOS bash 3.2 / Alpine BusyBox legs) and `.github/workflows/ticket-perf-regression.yml` are at 100% failure rate over their visible history. These are exactly the workflows that would surface bash-3.2 incompat, BusyBox shellisms, SIGPIPE-on-Linux divergence, and platform-conditional script bugs.

**Evidence:**
- `gh run list --workflow=ticket-platform-matrix.yml --limit 10` → all FAILURE (last 10 runs, 2026-04-24 to 2026-04-26).
- `gh run list --workflow=ticket-perf-regression.yml --limit 5` → all FAILURE.
- `.github/workflows/ticket-platform-matrix.yml:35-46` — declared matrix legs `linux-bash4`, `macos-bash3`, `alpine-busybox`.
- `.github/workflows/ticket-platform-matrix.yml:8-9` — push trigger on `main` only; not pre-merge. Even if the workflow were green, it would not gate PRs.
- No open ticket clearly tracking the persistent red status of either workflow as a CI-infrastructure bug; they appear to be silently tolerated.

**Attribution:** Patterns **8** directly, **1** and **4** by virtue of being the workflows that would surface them.

---

### G9. Test runs in CI are not hermetic

**Description:** GitHub Actions runs inherit the runner environment; no DSO CI job explicitly unsets `CLAUDE_PLUGIN_ROOT`, sets a clean `PATH`, uses `mktemp HOME`, or runs with `set -uo pipefail` shell flags. The hermetic environment that would expose Pattern 1 is never realized.

**Evidence:**
- `.github/workflows/ci.yml` — no `env:` block clearing `CLAUDE_PLUGIN_ROOT`; `run:` steps use default GitHub Actions shell.
- `validate.sh:87-88` — uses `"${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"` fallback. The fallback path is never exercised in CI because the fallback only fires when the variable is unset, and CI is not configured to unset it.
- The `portability-smoke.yml` workflow does run with no `CLAUDE_PLUGIN_ROOT`, but only smoke-tests the dso shim sentinel — it does not exercise the test runners or hooks.

**Attribution:** Patterns **1**, **2**, **3**.

---

### G10. Skill content has no anti-drift gate

**Description:** Skill bodies are edited freely; a normal edit can remove behavioral guidance (e.g., `39b0-130d`/`ce2bcbde94` had to restore `debug-everything` SKILL.md content from git). No automated check asserts that key sections still exist post-edit.

**Evidence:**
- `plugins/dso/scripts/check-referential-integrity.sh` — checks paths reference existing files; does not check that referenced section headings are present.
- `plugins/dso/scripts/check-contract-schemas.sh` — validates contract files, not skill bodies.
- `plugins/dso/skills/shared/prompts/behavioral-testing-standard.md:1-6` — explicitly notes "two parallel sources of truth" between this prompt and the agent files, intentionally accepted as temporary; no follow-up gate checks they remain in sync.
- Memory entry `feedback_named_review_agents.md` documents that the user has had to repeatedly correct review-agent dispatch patterns — the skills drift away from the intended pattern over time.

**Attribution:** Pattern **6** primarily; contributes to **5** when the section that drifts is a hard-gate clause.

---

### G11. Config-key documentation is decoupled from config-key usage

**Description:** New keys land in `dso-config.conf` without a paired update to `plugins/dso/docs/CONFIGURATION-REFERENCE.md`. There is no pre-commit gate enforcing the link.

**Evidence:**
- `plugins/dso/docs/CONFIGURATION-REFERENCE.md` exists and is comprehensive but is manually maintained (header notes a `last_synced_commit`).
- No hook in `.pre-commit-config.yaml` cross-references config keys against documentation.
- Tickets `a190-d780` (`commands.test_dirs` undocumented) and `93f9-de68` (`w21-bsnz` config validation behavior unspecified) are concrete instances of the gap.

**Attribution:** Pattern **7**.

---

### G12. `SIGPIPE / pipefail` antipattern has no static-detection gate

**Description:** Pattern 4 was remediated by hand across 26+ files (`b9358f95eb`, `0113ab66d9`, `465c296026`) but no gate prevents new instances. The audit found ~114 files still containing some form of `echo … | grep -q` in `plugins/dso/`, including hooks (`pre-commit-review-gate.sh:259`, `record-test-status.sh`, `pre-commit-test-gate.sh`, `pre-commit-test-quality-gate.sh`, `track-cascade-failures.sh`, `track-tool-errors.sh`, `taskoutput-block-guard.sh`).

**Evidence:**
- `plugins/dso/hooks/pre-commit-review-gate.sh:259` — current instance of `echo "$_worktree_files" | grep -qxF "$_msf"`.
- shellcheck, even at `--severity=warning` in CI, does not flag this pattern (no SC rule for SIGPIPE-on-pipefail).
- Ticket `999e-cf69` documents that one instance survived the 26-file sweep (`e241-41b2`) and was discovered later.

**Attribution:** Patterns **4** and **3** (Pattern 4 is itself an instance of Pattern 3 — antipattern recurring across files).

---

## Pattern → Gap traceability

| Pattern | Gaps |
|---|---|
| 1. Environment hermeticity | G1, G4, G7, G9 |
| 2. Test-runner divergence | G2, G4, G7, G9 |
| 3. Identical-root-cause regressions | G6, G7, G9, G12 |
| 4. SIGPIPE / pipefail | G1, G4, G7, G8, G12 |
| 5. LLM-behavioral degradation clauses | G3, G5 |
| 6. Sub-agent boundary drift | G3, G10 |
| 7. Spec / documentation gaps | G11 |
| 8. CI-only multi-platform failures | G8 |

## Alternative gap-grouping considered

- **Single "validation surface is syntactic, not environmental" mega-gap** instead of G1 / G4 / G9 / G12. Kept split because the remediations land in different files (pre-commit hooks vs. reviewer rubrics vs. CI workflow vs. AST checker) and conflating them would obscure ownership.
- **Single "skill prose permissiveness" mega-gap** instead of G3 / G5 / G10. Kept split because G3 is authoring-time language, G5 is reviewer-time override, and G10 is post-edit drift; the controls are different in each.
- **G6 could be reframed as "missing ratchet for fix-bug" rather than a prior-art exclusion.** Both framings point at the same fix surface; the prior-art-protocol framing is sharper because it cites a concrete rule that contradicts the lesson of the recurrence data.
