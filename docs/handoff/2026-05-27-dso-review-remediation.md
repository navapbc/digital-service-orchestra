# Session Log: DSO Review Evaluation & Remediation

**Date**: 2026-05-27
**Branch**: `claude/dso-review-evaluation-TmEf0`
**Session ID**: `01CG5136HYq5LHBvmYyp6MM5`

## What this session produced

Evaluated an external static review of the DSO plugin (8 findings), drafted and
iterated on a remediation plan through three opus-subagent review rounds,
dropped one finding (F-01) due to workflow-complexity risk, executed the
remaining four (F-08/F-06/F-05/F-02), then performed a four-agent deep-tier
review and applied 11 validated correctness/verification/hygiene fixes.

**End state**: branch contains 7 commits, 81 test assertions across 5 suites,
3 new pre-commit lints, all green.

## Commit chain (chronological)

| SHA | Scope |
|-----|-------|
| `9b3dc47` | Initial remediation plan (F-01, F-05, F-06, F-08) |
| `50bbe6a` | Added F-02 to plan |
| `fd4787f` | First ground-truth revision (corrected branch-naming model) |
| `c2ae1af` | F-01 dropped at user direction; F-02 API-outage protections |
| `ae87edd` | Third opus-review cleanup of plan |
| `6013912` | **F-08 implementation** — stale-term rewrites + phrase-based lint |
| `3bcef3d` | **F-06 implementation** — `tickets.directory` config drift fix + lint |
| `4984bd9` | **F-05 implementation** — default-branch resolver + cache invalidation |
| `059747a` | **F-02 partial implementation** — gate-tier doctrine + 2 Tier A flips |
| `b773fd3` | **Deep-review fixes** — 11 validated findings from 4-agent review |

## Plan iteration history

The plan went through three review rounds. Each round was a planned write →
opus subagent review → revise loop. Iteration was driven by the user's observation
that "agents are repeatedly hallucinating incorrect behavior" about the workflow.

### Round 1 — initial plan
- Opus reviewer landed with "Land with significant revisions" — 4 blocking, 5
  significant, 3 minor issues
- Key finding: a critical workflow file existed that I'd missed
  (`.github/workflows/review-sub-pr.yml`), which invalidated the foundational
  premise of F-01

### Round 2 — ground-truth revision
- Reframed F-01 around the real branch hierarchy:
  `worktree-agent-* → worktree-YYYYMMDD-HHMMSS → main` (not `session-*` as
  the documentation suggested)
- Opus reviewer still found critical issues: `review-sub-pr.yml` already runs
  per-sub-branch reviews; the "KNOWN GAP" wording in INSTALL.md is stale; the
  in-flight `sub-pr-cutover` migration framework would conflict with naive
  F-01 work

### Round 3 — F-01 dropped
- User decision: "drop F-01, and create a revised plan for the remaining steps.
  the workflow is complex enough that agents are repeatedly hallucinating
  incorrect behavior, which creates too much of a risk."
- Final plan covered F-02/F-05/F-06/F-08 only. Opus reviewer verdict: **Land**
  with 5 mechanical cleanup edits.

## Execution summary

### F-08 — Stale "skeleton/walking-skeleton" headers (~1 hr, commit 6013912)

**Delivered**:
- Rewrote stale headers in `merge-to-main-pr.sh`, `recipe-executor.sh`,
  `dso_reconciler/__main__.py`, `recipe-adapters/rope-adapter.sh`
- New `plugins/dso/scripts/check-stale-terms.sh` — phrase-based lint
  (avoids false positives on legitimate single-word uses)
- Per-line `# stale-term-ok` escape annotation
- Path exclusions for `tests/`, `docs/designs/`, `docs/adr/`, `docs/archive/`,
  `CHANGELOG*`, and the lint script itself
- Wired as `stale-terms-check` pre-commit hook
- `tests/scripts/test-check-stale-terms.sh` — 10 assertions

### F-06 — `tickets.directory` config drift (~1–2 hr, commit 3bcef3d)

**Delivered**:
- `merge-to-main-direct.sh` now honors `_CFG_TKDIR` at 5 previously-broken
  sites (L208/212/214/216 auto-commit, L442 conflict pattern, L782 post-merge
  stage, L836 tracker dir, L910 defensive fallback canonicalized)
- New `plugins/dso/scripts/check-merge-tickets-dir.sh` — annotation-driven
  literal guard scoped narrowly to the four merge/PR scripts (broader
  codebase's ~119 legitimate ticket-tracker literals deliberately
  out-of-scope as follow-up audit)
- Wired as `merge-tickets-dir-check` pre-commit hook
- `tests/scripts/test-merge-to-main-tickets-directory.sh` — 13 assertions

### F-05 — Default-branch resolver (~½–1 day, commit 4984bd9)

**Delivered**:
- New `plugins/dso/scripts/resolve-default-branch.sh` with precedence:
  config (`dso.default_branch`) → `git symbolic-ref` (local-first, no
  network) → `gh repo view defaultBranchRef` → literal `main` fallback
- Cache at `.git/dso-default-branch`, invalidated per-merge-run by
  `merge-to-main.sh` dispatcher
- Replaced literal `main`/`origin/main` references in `merge-to-main-pr.sh`,
  `merge-to-main-direct.sh`, `create-sprint-draft-pr.sh`
- **Direct-merge safety preserved**: assertion at
  `merge-to-main-direct.sh:411+` retains literal-`main` fast-path; only
  relaxes when operator explicitly opts in via `dso.default_branch`. Non-main
  hosts without opt-in get an actionable error naming the detected default
  branch + the exact config line to add
- Documented `dso.default_branch` config key in CONFIGURATION-REFERENCE.md
- `tests/scripts/test-resolve-default-branch.sh` — 9 assertions (later
  expanded to 12)

### F-02 — Gate-tier doctrine, partial (~1.5–2 days, commit 059747a)

**Delivered**:
- New `plugins/dso/hooks/lib/gate-unavailable.sh` helper:
  - `_dso_gate_unavailable <gate> <reason>`: writes JSONL audit + stderr
    signal
  - `_dso_gate_bypass_active <gate>`: paired-env-var bypass
    (`DSO_GATE_BYPASS_<UPPER>=1` AND non-empty `_REASON`), modeled on
    `DSO_ALLOW_EDIT_ON_MAIN` pattern
- **Tier A flips** (the actual safety improvement):
  - `pre-commit-test-gate.sh`: SIGTERM/SIGURG timeout now `exit 2` (was
    `exit 0` / silent fail-open). Contradictory rationale comment retracted
    in same commit.
  - `pre-commit-review-gate.sh`: empty `CURRENT_HASH` (compute-diff-hash
    failure) now `exit 2` (was `exit 0`)
- Tier annotations added to all 8 enforcement-annotated hooks
- New `plugins/dso/scripts/check-gate-tier-headers.sh` drift-detection lint;
  wired as `gate-tier-headers-check` pre-commit hook
- HOOKS-REFERENCE.md gate-tier doctrine section
- `tests/scripts/test-gate-unavailable.sh` — 19 assertions
- `tests/scripts/test-tier-a-fail-closed.sh` — 14 static regression assertions

**Deferred from F-02** (documented in commit message):
- `sprint/SKILL.md` SC coverage gate `GATE_UNAVAILABLE` emission at
  lines 458, 518, 576
- Phase B Step 1 three-strikes brake (per-tier scoping, reset on success)
- Cross-tier informational warning (`SC_CROSS_TIER_DEGRADED`)

Rationale for deferral: same workflow-complexity hallucination risk that
motivated dropping F-01. The Tier A flips on the actual git hooks deliver
the bulk of the safety improvement; SC gate work is additive (preserves
existing asymmetric fall-through) and can ship in a focused follow-up
with concurrent context on Phase B routing.

## Deep-tier review (commit b773fd3)

After execution, dispatched the canonical DSO deep-tier flow per
`plugins/dso/agents/code-reviewer-deep-*.md`:

- **Sonnet A — Correctness** specialist
- **Sonnet B — Verification** specialist
- **Sonnet C — Hygiene/design** specialist
- **Opus — Architectural synthesizer**

(Note: the DSO subagents aren't registered as Task subagent types in this
remote-execution environment. Dispatched as general-purpose agents with
model overrides matching each agent's frontmatter declaration.)

### Synthesizer verdict
"Fix required before merge" — substantive remediation gets the core gate-doctrine
infrastructure right, but ships with class-coherent incomplete-refactor defects
in F-05 and misleading-annotation problem in F-02. One short follow-up pass
lands it cleanly.

### Validity table

11 findings validated and fixed. 2 synthesizer overstatements rejected:

| Finding | Status | Fix |
|---------|--------|-----|
| C1 — `--ref main` at L933, 995 | valid | replaced with `"$_DEFAULT_BRANCH"` |
| C2/V5/H8 — JSONL escapes only `\` + `"` | valid (consolidated) | extracted `_dso_gate_json_escape` covering 5 chars |
| C3 — hyphen → invalid env var name | valid (latent) | added `_dso_gate_name_valid` boundary check |
| C4 — `_emit_conflict_data "main"` | valid | replaced at L644, 663 |
| V1+V2 — test-gate handler not asserting exit 2 / bypass-precedes | valid | added `_extract_function_body` + 2 block-extraction tests |
| V3 — cache-invalidation test claimed but missing | valid | added behavioral + static-guard tests |
| V4 — "committed" label tests staged state | valid | renamed label, made commit-tolerant |
| V5 — `timestamp`/`actor`/backslash assertions missing | valid | added 4 assertions + escape coverage |
| H1 — Tier A annotation on fail-open hooks | valid (narrowed) | downgraded 2 of 4 cited hooks to Tier B w/ INTENT note |
| H2 — `_EXPECTED_MAIN_BRANCH` naming | valid | renamed to `_EXPECTED_DEFAULT_BRANCH` |
| H3 — log strings still say "main" | valid (expanded) | replaced at 11 sites (synthesizer cited 4) |
| H4 — historical-context comment | valid | rewrote to current-behavior-only |
| C5 — pre-trap race window | rejected | theoretical, no operational trigger; synthesizer self-downgraded |
| H1 scope (4 hooks) | rejected | only 2 hooks have `_fail_open_on_timeout`; other 2 cited hooks have legitimate clean-path `exit 0` |

### Cross-dimensional patterns the synthesizer found

1. **Bypass-mechanism contract was under-specified across three dimensions**
   (C3 + V2 + H1 triangle). Closed by gate-name validation + handler-body
   tests + Tier annotation truthfulness.

2. **F-05's bulk replace was an unguarded refactor across a 1000-line script**
   (C1 + C4 + H3 — the same defect at three call-site classes). Closed by
   the fixes; recommended follow-up: `check-no-hardcoded-main.sh` lint to
   close the bug class systemically.

3. **F-02 tests validated presence but not behavior** (V1 + V2 + V5 root
   cause). Closed by adding `_extract_function_body` helper and lexical-order
   assertions.

4. **`check-gate-tier-headers.sh` enforces header presence, not truthfulness**.
   Recommended follow-up: extend the lint to parse `exit 0` on timeout paths
   and reject Tier A claims that don't match runtime behavior.

## Final test surface

| Suite | Assertions | Coverage |
|-------|-----------|----------|
| `test-check-stale-terms.sh` | 10 | F-08 lint patterns, escape annotation, path exclusions, false-positive guards |
| `test-merge-to-main-tickets-directory.sh` | 13 | F-06 config read, pathspec correctness, conflict-pattern matching, static regression guard |
| `test-resolve-default-branch.sh` | 12 | F-05 resolver precedence (4 steps), warning emission, exit codes, cache invalidation (behavioral + source-guard) |
| `test-gate-unavailable.sh` | 30 | F-02 helper: JSONL shape, all 6 audit fields, 4 escape chars, gate-name validation (4 rejection paths), bypass envelope |
| `test-tier-a-fail-closed.sh` | 16 | F-02 hook integration: header declarations, source includes, handler body composition, lexical order |
| **Total** | **81** | |

## Lints added

| Hook | Scope |
|------|-------|
| `stale-terms-check` | `plugins/dso/(scripts\|hooks)/**/*.{sh,py}` — production stale-vocabulary guard |
| `merge-tickets-dir-check` | `merge-to-main*.sh`, `create-sprint-draft-pr.sh` — F-06 regression guard |
| `gate-tier-headers-check` | `plugins/dso/hooks/*.sh` — F-02 Tier annotation drift guard |

## Open follow-ups (synthesizer recommendations)

| ID | Description | Status |
|----|-------------|--------|
| H5 | Factor resolver-loading block into `merge-helpers.sh` | Defer — premature; 2 callers; would touch the file most affected by F-05 |
| H6 | Track F-02 sprint/SKILL.md SC gate deferral as a ticket | **Recommend**: file when picking up F-02 SC gate work |
| H7 | Extract shared annotation-driven lint library | Defer — rule of three applies once 4th script lands |
| New | `check-no-hardcoded-main.sh` lint — closes F-05 refactor class systemically | **Recommend**: file as a lint-hardening task |
| New | Extend `check-gate-tier-headers.sh` to verify annotation truthfulness | **Recommend**: would have caught H1 in CI |
| F-01 | ci-pr enforcement work (sub-pr-cutover migration framework integration) | **Defer to human planning** per user direction |
| F-02 SC gates | `sprint/SKILL.md` SC coverage gate `GATE_UNAVAILABLE` emission + Phase B three-strikes brake | **Defer**: same workflow-complexity risk class |
| F-03 | `SPRINT_SESSION_ID` singleton repo variable | Out of scope per original plan |
| F-04 | Orchestration typing (Markdown→typed kernel) | Out of scope; reviewer's recommendation rejected as antithetical to design intent |
| F-07 | Telemetry auth (Lambda Function URL with `--auth-type NONE`) | Out of scope per original plan |

## Architectural takeaway

The user's "workflow complexity hallucination risk" framing was **validated in
kind** by what shipped. F-05 is the proof — its scope (replacing hardcoded
default-branch literal across a 1000-line script) was exactly the "broad
surface, many call sites, easy to miss one" pattern that motivated dropping
F-01. The implementation missed three call-site classes (`gh workflow run
--ref`, `_emit_conflict_data` payload, log-string text) the same way an
F-01 attempt would have.

However, this **doesn't invalidate shipping F-05** — the bug class here is
recoverable (one follow-up commit + the targeted regression-guard tests
landed). The asymmetry suggests evolving the mitigation rather than retracting
the work: the two recommended new lints (`check-no-hardcoded-main.sh` +
`check-gate-tier-headers.sh` truthfulness extension) would have caught the
incomplete-refactor and annotation-untruthfulness bug classes in CI. The
deferral framing for future workflow-touching work should evolve from "avoid
workflow complexity" to "ship workflow complexity behind mechanical lint
guards."

## Files added

```
plugins/dso/hooks/lib/gate-unavailable.sh
plugins/dso/scripts/resolve-default-branch.sh
plugins/dso/scripts/check-stale-terms.sh
plugins/dso/scripts/check-merge-tickets-dir.sh
plugins/dso/scripts/check-gate-tier-headers.sh
tests/scripts/test-check-stale-terms.sh
tests/scripts/test-merge-to-main-tickets-directory.sh
tests/scripts/test-resolve-default-branch.sh
tests/scripts/test-gate-unavailable.sh
tests/scripts/test-tier-a-fail-closed.sh
docs/designs/dso-review-remediation-plan.md
docs/handoff/2026-05-27-dso-review-remediation.md  (this file)
```

## Files modified

```
.pre-commit-config.yaml
plugins/dso/docs/CONFIGURATION-REFERENCE.md
plugins/dso/docs/HOOKS-REFERENCE.md
plugins/dso/hooks/check-tickets-boundary.sh
plugins/dso/hooks/pre-commit-enforcement-boundary-check.sh
plugins/dso/hooks/pre-commit-review-gate.sh
plugins/dso/hooks/pre-commit-test-gate.sh
plugins/dso/hooks/pre-commit-test-quality-gate.sh
plugins/dso/hooks/pre-commit-ticket-gate.sh
plugins/dso/hooks/review-gate.sh
plugins/dso/hooks/review-integrity-guard.sh
plugins/dso/scripts/create-sprint-draft-pr.sh
plugins/dso/scripts/dso_reconciler/__main__.py
plugins/dso/scripts/merge-to-main-direct.sh
plugins/dso/scripts/merge-to-main-pr.sh
plugins/dso/scripts/merge-to-main.sh
plugins/dso/scripts/recipe-adapters/rope-adapter.sh
plugins/dso/scripts/recipe-executor.sh
```
