# Observed Failure Patterns — 2026-04-26

## Summary

Analysis of the last ~150 commits, all open and ~22 recently closed bug tickets, and the last 50 GitHub Actions runs surfaces **eight recurring failure patterns** in code that has reached `main` (or local `validate.sh`-passing state) and subsequently required a fix. The patterns are ranked by frequency and recurrence within the most recent ~30-day window.

| # | Pattern | Approximate share of recent fixes | Discovery channel |
|---|---|---|---|
| 1 | **Environment hermeticity violations** (CLAUDE_PLUGIN_ROOT, `set -u` unbound vars, BASH_SOURCE under pre-commit's symlink, bash 3.2 vs 4.x, TZ) | ~25% | CI + isolated test runs |
| 2 | **Test-runner / gate semantic divergence** (bash-runner vs suite-engine, RED-marker tolerance, validate.sh scope vs CI scope, command_hash tracking) | ~15% | `validate.sh --ci` and CI |
| 3 | **Identical-root-cause regressions** (the same bug class fixed in script A, then re-discovered in script B months later) | ~10% (cross-cuts #1) | Manual / CI |
| 4 | **`set -o pipefail` + SIGPIPE on `… \| grep -q`** (Linux-strict, macOS-lenient) | ~8% | Linux CI only |
| 5 | **LLM-behavioral: skills with permissive degradation/escape clauses** (agent self-rationalizes skipping a sub-agent dispatch or gate) | small absolute count, **highest blast radius** | User catches post-hoc |
| 6 | **Sub-agent boundary / contract drift** (skill text drifts away from intended behavior; missing prescriptive instructions; instruction file restored from git) | ~10% | Debug-everything sessions |
| 7 | **Spec / documentation gaps** (config keys undocumented, integration error contracts undefined, success-criteria ambiguous) | ~8% | Sprint or downstream consumer |
| 8 | **CI-only multi-platform / perf failures** (`ticket-platform-matrix`, `ticket-perf-regression` — 100% failure rate, no local repro) | persistent | CI |

A ninth meta-pattern, **merge-artifact noise** (worktree rebases producing duplicate fix commits with the same ticket ID), accounts for ~23% of raw fix-commit count but is not a code defect; it is included only to discount it from the analysis.

### Cross-cutting observations

- **Local-vs-CI divergence is the dominant root cause across patterns 1, 2, 3, 4, and 8.** Code that passes `validate.sh` locally still fails CI because the local environment carries pre-set state (CLAUDE_PLUGIN_ROOT exported by parent), uses different test harnesses (`run-hook-tests.sh` vs `bash-runner.sh`), runs on a different bash major version, or skips entire workflows (multi-platform matrix, perf regression).
- **Identical patterns recur weeks/months apart in different files.** Bug `fe45-0b58` (skip-review-check.sh CLAUDE_PLUGIN_ROOT unbound) explicitly cites `09d8-11f0` (pre-commit-format-fix.sh — same root cause). This indicates a missing systematic fix, not a per-script oversight.
- **LLM-behavioral failures are rare in count but high in severity.** A single brainstorm-skill bug (`3dae-af1a`) produced an entire epic without scrutiny because the agent treated a "graceful degradation" clause as opt-out license. Pattern is consistent with `feedback_named_review_agents.md` and `feedback_completion_verifier_must_use_named_agent.md` memory entries.
- **The release gate (`scripts/release.sh` precondition #8 → `validate.sh --ci`) acts as the de facto integration test.** Most clusters were detected here, not by per-file pre-commit hooks. This means the pre-commit gate is letting through entire categories of regressions.

---

## Detailed evidence

### Pattern 1 — Environment hermeticity violations (~25%)

Tests and scripts assume environment state pre-populated by the calling Claude Code session and break when run in a clean shell, container, or pre-commit's symlinked environment.

| Ticket | Commit | Failure |
|---|---|---|
| `fe45-0b58` | `dcbe98f3ef` | `skip-review-check.sh` references `$CLAUDE_PLUGIN_ROOT` under `set -u` → unbound variable → 27/56 tests fail in clean env |
| `09d8-11f0`, `a190-d780` | `e913a71d5a` | `pre-commit-format-fix.sh` same pattern — 5/11 tests fail; identical root cause to `fe45-0b58` two months earlier |
| `82ad-7bb3` | `f5a055d1fa` | `bash-runner.sh` does not export `CLAUDE_PLUGIN_ROOT` before sourcing suite-engine; child processes in temp git repos cannot resolve plugin paths |
| `97a7-4504` | `495c8c4b4f` | `bash-runner.sh` fallback path needed annotation under plugin-self-ref check |
| `4191-9096`, `0a47-9631` | `2261fcc83b`, `0968b46917` | `declare -A` (associative array) used in scripts that must run on bash 3.2 (macOS default); converted to indexed array |
| `a40e-ab52` | (in flight) | `check-tickets-boundary.sh` resolves `BASH_SOURCE` via pre-commit's symlinked temp path → silent docs/ exclusion failure |
| `096e-f044` | `eafb962c14` | `test_default_state_file_includes_repo_hash` not hermetic — leaks `TEST_BATCHED_STATE_FILE` env var |
| `8f1f-b093` | `a63fabd221` | `ticket_show()` spawned `python3` for JSON; replaced with bash+jq for environments without python3 |

**Root-cause hypothesis:** Hermeticity is treated as a per-script concern rather than a project invariant. There is no script-entry guard that asserts required env vars or refuses to run unset. The test matrix does not include "clean shell" or "bash 3.2 macOS" as first-class CI legs.

### Pattern 2 — Test-runner / gate semantic divergence (~15%)

Multiple test runners exist (`bash-runner.sh`, `suite-engine.sh`, `run-hook-tests.sh`, `test-batched.sh`) and have drifted apart in critical semantics.

| Ticket | Commit | Failure |
|---|---|---|
| `7225-7708` | `48a84914e7` | `bash-runner.sh` does not honor `SUITE_TEST_INDEX` RED markers that suite-engine tolerates; ~25 false-positive failures vs CI |
| `bf39-4494` | `dc53a44c51` | `validate.sh --ci` infinite PENDING loop because per-file timeout >45s under sequential runner |
| `e2b6-1059` | `d1f7877896` | `validate.sh` test scope diverges from CI workflow (validate covers `tests/skills`, CI covers only `tests/hooks` + `tests/scripts`) — main stays green while skills tests fail |
| `e8a9-136f` | `9b073eb686` | `figma-pullback` test missing RED-marker registration |
| `8305-2091` | (open/recent) | `record-test-status.sh --source-file` merge preserves stale failures — fixed tests not re-run |
| `610f-c021` | (open) | `record-test-status.sh` blocked by `pre-bash-functions.sh` guard within `/dso:commit` workflow |

**Root-cause hypothesis:** No single source of truth for "test runner contract." When suite-engine gets a new feature (RED-zone tolerance, command_hash), bash-runner is updated reactively after a CI failure, not as part of the same change. There is no contract test asserting cross-runner equivalence.

### Pattern 3 — Identical-root-cause regressions (~10%, overlaps Pattern 1)

The same bug class is fixed in one location, then independently re-discovered in another.

- CLAUDE_PLUGIN_ROOT under `set -u`: `09d8-11f0` (pre-commit-format-fix.sh) → `fe45-0b58` (skip-review-check.sh) → `82ad-7bb3` (bash-runner.sh) → `97a7-4504` (annotation follow-up). At least four separate tickets, identical root cause, mechanical fix each time.
- `echo … | grep -q` SIGPIPE under `pipefail`: `e241-41b2` (bulk replacement across 26 files in `b9358f95eb` + `0113ab66d9`) and `999e-cf69` (a 27th instance discovered later in `ticket-push-rebase-conflict`).
- `declare -A` on bash 3.2: `4191-9096` and `0a47-9631` — two separate scripts, same fix.

**Root-cause hypothesis:** When the first instance is fixed, the lesson is encoded only in commit messages and CLAUDE.md prose, not in an automated check that grep/AST-scans the whole tree for the same antipattern.

### Pattern 4 — `set -o pipefail` + SIGPIPE on `grep -q` (~8%)

Strictly Linux-CI-only failure mode. Pipeline `echo "$x" | grep -q "$y"` exits 141 (SIGPIPE) when `grep -q` exits early after a match; under `set -uo pipefail` the entire pipeline is non-zero, so the `if` branch evaluates false even on a match. macOS local development does not reproduce.

- `e241-41b2`: 50+ instances replaced with here-strings (`grep -q "$y" <<< "$x"`) across 26 files.
- `999e-cf69`: a 27th instance later discovered in `ticket-push-rebase-conflict` handling.

### Pattern 5 — LLM-behavioral: permissive degradation clauses

| Ticket | Behavior |
|---|---|
| `3dae-af1a` | `/dso:brainstorm` Phase 2 Step 4 contained "gracefully degraded with logged rationale" wording. Agent treated this as license to skip the scrutiny pipeline sub-agent dispatch entirely, then applied `brainstorm:complete` tag. User caught post-hoc. |
| `3da0-dc8c` | Brainstorm produced an epic (`w21-bsnz`) with no agent contract definitions; downstream implementation agents would have invented incompatible interfaces. Closed via epic annotation rather than fix. |
| `39b0-130d` | `debug-everything` SKILL.md lost behavioral guidance during an earlier edit; restored in `ce2bcbde94`. |
| `41da18e699` | "Mega-fix" of 10 tickets in `debug-everything` skill — instruction gaps, missing steps. |
| `44f2-b9ed`, `5eec-a87d` | Reviewer Step 3 missing variable-assignment instruction; agents skipped a required step. |

**Root-cause hypothesis:** Skill prose contains hedging language ("gracefully degrade", "if appropriate", "may"). Where the intent is hard-required dispatch of a sub-agent, the prose still reads as a soft recommendation. Memory entries (`feedback_completion_verifier_must_use_named_agent.md`, `feedback_named_review_agents.md`, `feedback_subagent_tier1_compliance.md`) demonstrate the user has had to add CLAUDE.md rules reactively each time an agent took the escape clause.

### Pattern 6 — Sub-agent boundary / contract drift (~10%)

Skills and agent files lose required content via routine edits, or different consumers of the same artifact disagree on its contract.

- `39b0-130d` / `ce2bcbde94`: `debug-everything` SKILL.md behavioral guidance had to be restored.
- `93f9-de68`: `w21-bsnz` config validation behavior unspecified — three plausible failure modes, no decided one.
- `2c2f-821d`: `review-gate` telemetry missing required fields.
- `48ac-f0c1`: `check-referential-integrity.sh` validation broken.
- `59d6-c470`: `reviewer-fragment-staleness` rejected valid fragments.
- `63c3-9f22`: `check-shim-refs.sh` missed literal-path violations it was supposed to catch.

### Pattern 7 — Spec / documentation gaps (~8%)

Config keys, error contracts, and success criteria are added without paired documentation, leading to downstream agents inventing behavior.

- `a190-d780`: `commands.test_dirs` config key undocumented.
- `93f9-de68`: validation behavior not specified.
- `f3ce-f999`: no sanctioned CLI path to archive open orphan tickets — workaround required.
- `b5da-8d7f`: empty ticket description; test-process docs unclear.
- LLM-behavioral subset: integration error surfaces (Jira, ACLI) not mapped in skill prompts; e.g. `0cd6-57d6` (ACLI assignee error pattern), `275d-dfd5` (JQL datetime → service-account TZ).

### Pattern 8 — CI-only multi-platform / perf failures

Two workflows are persistently broken with no local repro pathway:

- `ticket-platform-matrix.yml`: **7/7 recent runs failed (100%)**. Multi-platform matrix `linux-bash4`, `macos-bash3`, `alpine-busybox`. Triggered by changes to `ticket-lib-api.sh` or `test-ticket-*.sh`.
- `ticket-perf-regression.yml`: **5/5 recent runs failed (100%)**. Triggered by `ticket-lib-api.sh` changes; depends on hyperfine installer.

By contrast: `template-real-url-e2e.yml`, `inbound-bridge.yml`, `outbound-bridge.yml`, `ci-python-skills.yml`, `portability-smoke.yml`, `ticket-lifecycle.yml` are healthy. The two broken workflows are exactly those that test cross-platform / performance behavior — i.e., precisely the dimensions Pattern 1 is most likely to violate.

---

## Notable secondary observations

- **"Fix the fix" chains.** `0e38-a5da` (observability for `bridge-inbound.py`) was fixed across four commits over four days (`e81fe14062`, `cf301ecad2`, `58a393f235`, `0ebc0dae1e`). Suggests the underlying issue was not understood at first attempt and patches accumulated.
- **Emergency hotfixes without ticket IDs.** Two `shim-violations` commits (`2839e6e68d`, `553d7b07a1`) were applied without bug tickets; they fixed pre-existing violations against a newly enforced gate.
- **Release-gate as integration test.** 16 of the recent 22 closed bugs were detected by `validate.sh --ci` blocking `scripts/release.sh`. The pre-commit hook layer is admitting these regressions; only the release gate catches them.

## Alternative groupings considered

- **Combine Pattern 1 + Pattern 3 into "hermeticity."** They share root cause, but Pattern 3 is the *meta* observation that the project has not generalized fixes — kept distinct because the mitigation surface differs (per-script env guard vs. cross-tree static check).
- **Combine Pattern 5 + Pattern 6 into "skill-as-spec drift."** They both concern instruction-file integrity. Kept distinct because Pattern 5 is "the spec is permissive by design" and Pattern 6 is "the spec was correct then drifted." The remediations target different process points (authoring vs. editing).
- **Combine Pattern 2 + Pattern 8.** Both are runner/environment divergence. Kept distinct because Pattern 2 has local repro paths (compare runners) while Pattern 8 has none (CI-only matrix).
