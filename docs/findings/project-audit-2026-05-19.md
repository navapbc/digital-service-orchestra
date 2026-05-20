# DSO Project-Wide Quality Audit — 2026-05-19

Scope: full-project audit for inconsistencies, contractual mismatches, process gaps, stale documentation, invalid references, and anti-patterns. Conducted via 12 parallel opus subagents (dimension-scoped); 16 parallel opus validators (one per remediation cluster).

Companion artifact: `docs/findings/change-detector-audit-2026-05-19.md` (narrow test-quality audit; surfaces 12 DELETE-tier change-detector tests).

## Methodology

- 12 dimension-scoped opus subagents enumerated findings across: contract drift, invalid references, CLAUDE.md hygiene, skill cross-references, hook wiring, config-key drift, anti-patterns, sub-agent dispatch, workflow phase consistency, test quality, and documentation freshness.
- 16 opus validator subagents independently re-verified each remediation cluster (problem presence + fix effectiveness) and surfaced additional sites the original audit missed.
- Severity ladder: 🔴 critical (load-bearing breakage), 🟠 major (correctness/clarity drift), 🟡 minor (cosmetic).

## Validation Outcomes (R1–R35)

| Outcome | Count | Items |
|---|---|---|
| CONFIRMED as stated | 18 | R2, R3, R4, R6, R7, R9, R10, R12, R14, R15, R16, R17, R19 (5/5), R23, R24, R26, R27, R32 |
| PARTIAL — fix scope adjusted | 6 | R1, R5, R8, R20, R25, R28 |
| CONFIRMED + audit missed sites | 5 | R3, R4, R13 (+14 sites), R21 (+6 orphan agents), R22 (+1 model ID) |
| NOT PRESENT | 0 | — |

No false positives; several remediations needed scope expansion or correction.

---

## 🔴 Critical Findings

### R1 — `/dso:commit` allowlist drift (PARTIAL)

**Original premise wrong**: `commands/commit.md` and `commands/end.md` exist as Claude Code slash commands; the resolver tries `commands/<name>.md` before `skills/<name>/SKILL.md`. User-typed `/dso:commit` works; CLAUDE.md rule 10 already correctly distinguishes user-typed from orchestrator Skill-tool invocation.

**Actual defect**: `plugins/dso/scripts/check-skill-refs.sh:32` `DSO_SKILLS` allowlist names `commit` and `end` (which aren't skills) and omits 13 real skills (`create-bug`, `end-session`, `fp-recovery`, `generate-claude-md`, `init`, `prioritize-epics`, `remediate-arch-evidence`, `respond-to-pr-comments`, `review-protocol`, `review-stats`, `tickets-health`, `ui-discover`, `using-dso`). Typos in `/dso:<name>` references therefore silently pass the gate.

### R2 — Onboarding installs broken pre-commit hooks (CONFIRMED)

`plugins/dso/skills/onboarding/SKILL.md` lines 1289, 1291, 1300, 1301 reference `${CLAUDE_PLUGIN_ROOT}/hooks/dispatchers/pre-commit-{test,review}-gate.sh`. Real files live one segment up (`hooks/pre-commit-...`). The `dispatchers/` subdir exists but contains Claude Code tool-use dispatchers, not git pre-commit gates. The `cp` calls at 1300-1301 fail with ENOENT; the `echo` calls at 1289/1291 silently write broken paths into `.husky/pre-commit`, failing later at commit time. All four sites are isolated to this one file.

### R3 — Sprint `STORY_BRANCH` capture (CONFIRMED, broader blast radius)

`plugins/dso/scripts/create-story-branch.sh:44, 49` emit `STORY_BRANCH=story/<epic>/<story>` on **stdout**. `plugins/dso/skills/sprint/SKILL.md:1278` captures it via `STORY_BRANCH=$(bash ...)`, so `$STORY_BRANCH` becomes the literal string `STORY_BRANCH=story/...`. Downstream consumers:

- `plugins/dso/skills/sprint/SKILL.md:2104` calls `merge-story-branch.sh "$STORY_BRANCH" "$STORY_ID"` → `merge-story-branch.sh:18` calls `git rev-parse --verify refs/heads/STORY_BRANCH=story/...` → guaranteed failure.
- `plugins/dso/skills/sprint/SKILL.md:2095` exports `BRANCH="$STORY_BRANCH"` to `merge-to-main.sh` → the malformed value propagates into the PR pipeline in ci-pr mode.
- `tests/scripts/test-create-story-branch.sh:208, 238` currently asserts the key=value form is the stdout contract — must be updated as part of the fix.

### R4 — CLAUDE.md story-merge invariant (CONFIRMED, two errors)

CLAUDE.md:59 (Architecture pointers, "Story-branch invariant") has **two** errors:

1. Names the wrong trailer: says `DSO-Story:` (per-task attribution trailer written by `apply-attribution-trailers.sh:320`); actual merge-commit trailer is `DSO-Story-Merge:` written by `merge-story-branch.sh:23`.
2. Names the wrong enforcer: says `check-sprint-trailer.sh` (which validates `^DSO-Story:` on **task** commits, line 50); actual merge-commit enforcer is `check-session-branch-invariant.sh:13` (`grep '^DSO-Story-Merge:'`).

The two trailers are orthogonal per `plugins/dso/docs/contracts/dso-story-merge-trailer.md:66`.

### R5 — CLAUDE.md cites deprecated config keys (REVISED)

CLAUDE.md:60 lists `merge.strategy`, `enforcement.strategy`, `worktree.isolation_enabled` as canonical knobs. All three are documented as **Deprecated — consolidated into `dso.workflow`** in `CONFIGURATION-REFERENCE.md:685, 1229, 1245, 1870` and sentinel-locked in `read-config.sh:92-103`.

The sentinel lockout is conditional on `.claude/.dso-config-v2-migrated` existing — that file is **intentionally absent** during the S3→S6 window (comment at `read-config.sh:93-94`), so today the keys still read normally. The defect is documentation drift; no live time-bomb. `.claude/dso-config.conf:102` sets `worktree.isolation_enabled=true` which is a no-op today (only `dso.workflow=ci-pr` controls isolation).

### R6 — Verifier-verdict contract↔script exit-code mismatch (CONFIRMED)

`plugins/dso/docs/contracts/verifier-verdict.md:188` says unrecognized P1 → BLOCKED (exit 1, with warning). Exit-code table at lines 199-203 lists exit 2 for "P1 absent, JSON malformed, or no input provided" but is silent on "unrecognized value". `plugins/dso/scripts/check-verifier-verdict.sh:96-103` exits 2 for both the absent (`""`) and unrecognized (`*`) cases. This is the P1 story-closure gate (CLAUDE.md rule 20). Today the orchestrator treats all non-zero exits as halt, so visible blast radius is the misleading "parser error" classification; future tooling that distinguishes parse-error from gate-block fails open on unrecognized values.

### R7 — `suggestion` severity missing from enum (CONFIRMED)

`plugins/dso/docs/contracts/review-findings-schema.md:128` enum lists `{critical, important, minor}`. `plugins/dso/scripts/dso_ci_review/runner.py:1065, 1132` writes `severity = "suggestion"` after auto-downgrade (novelty gate and defended-finding suppression). The contract itself describes `suggestion` extensively in lines 163, 164, 221 — the enum table is the outlier. Strict validators based on the enum would silently drop legitimate findings.

### R8 — `make test-unit-only` in agent-executed prompts (REVISED scope)

CLAUDE.md rule 19 prohibits `make test-unit-only` from the Bash tool (~73s tool-timeout ceiling). Original audit cited 5 sites; validator confirms only 2 of those are violations + 2 missed locations:

- **Violations** (agent-executed): `plugins/dso/docs/ACCEPTANCE-CRITERIA-LIBRARY.md:51-52, 113`; `plugins/dso/skills/sprint/prompts/task-execution.md:78, 83` (missed); `plugins/dso/docs/workflows/prompts/review-fix-dispatch.md:165` (missed).
- **Not violations**: `MIGRATION-TO-PLUGIN.md:35, 172` (targets human migrator); `PRE-COMMIT-TIMEOUT-WRAPPER.md:91` (runs inside a 120s timeout wrapper).

**Correction**: `validate.sh --ci` is **not** a substitute — it wraps `make test-unit-only` with a 600s timeout (`validate.sh:52, 128`), so it also exceeds the Bash-tool ceiling. The correct replacement is `test-batched.sh` (per-test exit codes; purpose-built for the ~73s ceiling).

---

## 🟠 Major Findings (validated, summarized)

- **R9**: 14 actively-dispatched agents absent from `AGENTS.md` (investigator pyramid ×9; huge-diff trio; arbiter; verifier; architectural-probe; bug-classifier-haiku; schema-correction). Audit's nomenclature for one (`huge-diff-refactor-anomaly`, not a 3rd reviewer variant) corrected.
- **R10**: 15 live hooks undocumented in `HOOKS-REFERENCE.md`; **2 standalone wrappers are dead code** (`tool-use-guard.sh`, `inject-using-dso.sh` — the in-lib functions are live; the standalone shims are not wired). Deletion candidates.
- **R11**: `review-gate.sh` is a dead wrapper (coverage intact via dispatcher). `plan-review-gate.sh` similarly orphaned. Host projects installed as files-only (not as plugin) have zero Layer 2 coverage — needs `INSTALL.md` note.
- **R12**: Three `check-*.sh` scripts listed in HOOKS-REFERENCE.md as hooks actually live in `scripts/` (wired via `.pre-commit-config.yaml`). Don't relocate; qualify with path column.
- **R13**: Rule-number citation rot extends to ~14 additional sites beyond the two cited. Proposed durability fix: stable anchors (`rule:fabrication`-style spans cited by content) + `check-rule-anchors.sh` CI gate.
- **R14–R16, R32**: CLAUDE.md bloat (rules 11, 18, 24, 25), duplicate rules (bug-close `--reason`, stdlib preference), unenforced-mixed-with-enforced "Always Do These", "see config for current value" hedge on `review.max_cycles` (default 4 is stable; inline it).
- **R17**: Three contract enum mismatches confirmed. `R17a` (ticket status `deleted`) — clarify contract that `deleted` is compiled-state, not event-payload. `R17b` (inference-incident affects_fields) — add `gate_verdicts`, `workflow_completion_checklist`. `R17c` (inference-envelope wire format) — document JSON form, add `inference_without_explicit_sourcing` to enum.
- **R18**: `attest_source` doc says "path" but producer writes worktree-ID basename. Low-impact (additive field). Amend contract.
- **R19**: 5 undocumented load-bearing config keys (`orchestration.max_agents`, `design.figma_collaboration`, `worktree.orphan_patterns`, `debug.session_ttl_hours`, `suggestion.tool_use_count_threshold`).
- **R20 (REVISED)**: `dso.plugin_root` is **NOT** orphan — shim resolver consumes it. Confirmed unused: `brainstorm.max_interaction_cycles`, `checks.assertion_density_cmd`.
- **R21 (REVISED)**: `second-source-verifier` shipped today as AC-satisfaction for epic `f9de-b7d9`; orphan-by-design. Recommended wiring: sprint Phase 9 optional audit. **+6 additional orphan agents discovered**: `bloat-blue-team`, `bloat-resolver`, `inference-incident-curator`, `huge-diff-{reviewer-light, reviewer-standard, refactor-anomaly}`.
- **R22 (CONFIRMED + 1 site missed)**: stale `claude-opus-4-5` at `region_split.py:427`, `local_workflow.py:187, 190`, **+ `dispatch.py:143` (audit miss)**.
- **R23**: 13 `/tmp/*.$$` PID-suffix temps in `ticket-lifecycle.sh`, `ticket-compact.sh` — mechanical `mktemp` migration.
- **R24**: 5 lib/*.sh files missing exec bit (16 of 21 in same dir are already 0755 — these 5 are outliers).
- **R25 (REVISED)**: `create-bug` has 6 callers (inline-execute pattern); not orphaned. Only `interface-contracts` (under-routed) and `verification-before-completion` (rule 16 + rule 20 overlap — deprecate?) are real candidates. Others correctly user-invocable.
- **R26**: Sprint↔preplanning duplicate-classification real bug (`--force-mode=full` flag in preplanning Step 1.5a, ~5-line fix). STATUS asymmetry is fragility, not a current bug.
- **R27**: Most sub-agent boundaries are trust-only because PreToolUse payload lacks an `is_subagent` flag. Only the reviewer-isolation guard is a clean hook candidate. Otherwise: doc-label "trust-only".

## 🟡 Minor Findings (validated, summarized)

- **R28**: T1, T2, T4, T5 confirmed. T3 count corrected: ~93 bash tests lack `set -euo pipefail` (not 148); ~69 after removing source-only helpers.
- **R29**: ADR `Status` format split 5/9 (not 4/10); include 0011 (third sub-variant). Add Superseded-by template line.
- **R30**: 2 missing `/dso:` prefixes confirmed.
- **R31**: `init` skill description (and `generate-claude-md`) lack trigger phrases; shadowed by onboarding.
- **R33**: Quick-Reference style inconsistency confirmed; prefer `${CLAUDE_PLUGIN_ROOT}/` form.
- **R34**: Phase-without-Step references in `remediate-arch-evidence/SKILL.md` confirmed.
- **R35 narrowed**: 2 of 4 sprint grep citations dropped (legitimate stdout-pipe / single-file verifier). Keep `retro/SKILL.md:80` and `remediate-arch-evidence/SKILL.md:246`.

## New Issues Surfaced During Validation

Items not in original audit, discovered by validators:

1. CLAUDE.md:59 names the **wrong enforcer script** for the story-merge trailer (wrapped into R4).
2. `plan-review-gate.sh` is similarly orphaned to `review-gate.sh` (wrapped into R11).
3. Host projects installed as files-only get zero Layer 2 coverage (R11).
4. 6 additional orphan agents (wrapped into R21).
5. 2 dead-code hook standalone wrappers (R10).
6. `dispatch.py:143` carries a 4th stale model ID (R22).
7. ~14 additional stale rule-number citations (R13).
8. 2 additional agent-executed `make test-unit-only` sites (R8).
9. Possible `dimension` enum drift in `review-findings-schema.md` (follow-up).

---

# Critical-Correctness Remediation Plan

The 8 critical items can ship as **3 small PRs**. Order matters only for PR-A (R3+R4 share `merge-story-branch.sh` invariants).

## PR-A: Sprint story-branch invariant (R3 + R4 + R2)

**Goal**: Restore the load-bearing story-branch invariant. R3 is broken in every sprint that reaches Phase F today; R4 misleads future spec readers; R2 ships broken hooks to every onboarded host project.

### A.1 — Fix `create-story-branch.sh` stdout contract (R3)

**Files**:
- `plugins/dso/scripts/create-story-branch.sh`
- `tests/scripts/test-create-story-branch.sh`
- (verify only) `plugins/dso/skills/sprint/SKILL.md:1278` capture pattern; no change needed.

**Change to `create-story-branch.sh`** at lines 44 and 49:
- Replace `echo "STORY_BRANCH=${_BRANCH}"` with two lines:
  1. `echo "STORY_BRANCH=${_BRANCH}" >&2` (preserve human-readable form on stderr for logs)
  2. `echo "${_BRANCH}"` (bare branch name on stdout for command substitution)

**Change to `test-create-story-branch.sh`** (4 assertion sites — confirmed by plan reviewer):
- Lines 95 (Test 4), 178 (custom_prefix), 208, 238 all assert the current key=value stdout form. Each must be split into:
  - stdout assertion: bare branch name
  - stderr assertion: `STORY_BRANCH=` form

**Validation**:
- Run `tests/scripts/test-create-story-branch.sh` — must pass with both new assertions.
- Run `bash plugins/dso/scripts/create-story-branch.sh test-epic test-story 2>/dev/null` → output must be a single bare branch name.
- Run `bash plugins/dso/scripts/create-story-branch.sh test-epic test-story 1>/dev/null` → output must be `STORY_BRANCH=...`.

**Risk**: Any other caller depending on the key=value stdout form would break. Validator confirmed only `sprint/SKILL.md:1278` (product code) and the test file consume it; `debug-everything/SKILL.md:733` references the script by name in prose only.

### A.2 — Fix CLAUDE.md story-merge invariant (R4)

**File**: `CLAUDE.md` line 59 only.

**Current text** (Architecture pointers, "Story-branch invariant" bullet):
> Phase E creates `story/<epic-id>/<story-id>` branch; Phase F merges with `DSO-Story:` trailer. Enforced by `check-sprint-trailer.sh`.

**Replacement**:
> Phase E creates `story/<epic-id>/<story-id>` branch; Phase F merges with `DSO-Story-Merge:` trailer (written by `merge-story-branch.sh`, enforced by `check-session-branch-invariant.sh`). A separate `DSO-Story:` trailer is written on individual task commits by `apply-attribution-trailers.sh` and enforced by `check-sprint-trailer.sh`. See `plugins/dso/docs/contracts/dso-story-merge-trailer.md`.

**Validation**:
- `grep -n "DSO-Story-Merge" CLAUDE.md` → at least one match at line 59 area.
- `grep -n "check-session-branch-invariant" CLAUDE.md` → match present.
- No other CLAUDE.md line mentions `DSO-Story:` in the story-merge context (verify by grep).

**Risk**: Doc-only change; no behavioral impact.

### A.3 — Fix onboarding `dispatchers/` paths (R2)

**File**: `plugins/dso/skills/onboarding/SKILL.md` lines 1289, 1291, 1300, 1301 only.

**Change**: Remove `dispatchers/` segment from all four lines. No template ripple (validator confirmed grep is clean).

**Validation**:
- `grep -n "dispatchers/pre-commit" plugins/dso/skills/onboarding/SKILL.md` → no matches.
- Test exists? If not, add to follow-up; do not gate this PR on adding one.

**Risk**: Hosts already onboarded with the broken paths have broken hook installs — but the failure is fail-loud (`cp` ENOENT or commit-time hook error), not silent corruption. They will re-run onboarding or fix locally.

**PR-A acceptance**:
- `tests/scripts/test-create-story-branch.sh` PASS.
- Manual: run a smoke epic through sprint Phase F locally; merge succeeds.
- `validate.sh --ci` PASS (will exceed Bash-tool ceiling — run via CI or `test-batched.sh`).

## PR-B: Contract reconciliation (R6 + R7)

**Goal**: Align verifier and review-findings contracts with their producers. Both are doc-only-or-script edits; can ship in one PR.

### B.1 — Fix verifier-verdict unrecognized-P1 exit code (R6)

**Files**:
- `plugins/dso/scripts/check-verifier-verdict.sh` lines 96-103
- `plugins/dso/docs/contracts/verifier-verdict.md` exit-code table (lines 199-203)

**Change to `check-verifier-verdict.sh:96-103`**:
- Restructure the case statement so `""` (absent) exits 2, and `*` (unrecognized) prints `WARNING: unrecognized P1 verdict '<value>'; treating as BLOCKED` to stderr and exits 1.

**Change to `verifier-verdict.md:199-203`** (exit-code table):
- Add a new row: `1 | BLOCKED (recognized: FAIL, BLOCKED, INCONCLUSIVE, or unrecognized P1 value)`.
- Update the existing row to: `2 | P1 absent (empty), JSON malformed, or no input provided`.

**Validation**:
- New test in `tests/scripts/test-check-verifier-verdict.sh` (or extend existing): feeds `{"P1": "WAFFLE"}` → asserts exit 1 + stderr contains `WARNING: unrecognized P1 verdict`.
- Feed `{}` (P1 absent) → asserts exit 2.
- Feed invalid JSON → asserts exit 2.

**Risk**: Any orchestrator path that branched on exit 2 specifically (vs treating all non-zero as halt) would change behavior on unrecognized-P1. Validator confirmed no such consumer exists in plugin scripts.

### B.2 — Add `suggestion` to review-findings severity enum (R7)

**File**: `plugins/dso/docs/contracts/review-findings-schema.md` only (around line 128).

**Change**: Update the severity-enum table from `critical | important | minor` to `critical | important | minor | suggestion`, with a clarifier note: "`suggestion` is the auto-downgraded class produced by the novelty gate and defended-finding suppression in `dso_ci_review/runner.py`; reviewers do not emit it directly."

**Validation**:
- `grep -n "suggestion" plugins/dso/docs/contracts/review-findings-schema.md` → at least 4 matches (enum, narrative paragraph 163, 164, 221).
- No producer/consumer change required; runner.py already writes the value.

**Risk**: Negligible. Doc-only change; aligns enum with already-running code.

**PR-B acceptance**:
- New verifier test passes.
- `grep` checks pass.
- No code behavior change beyond the verifier exit-code branch.

## PR-C: Documentation hygiene (R1 + R5 + R8)

**Goal**: Fix three doc/config drifts that don't share file scope but are small. Ship in one PR to minimize churn.

### C.1 — Regenerate `check-skill-refs.sh` allowlist (R1)

**File**: `plugins/dso/scripts/check-skill-refs.sh` line 32 area (the `DSO_SKILLS` variable).

**Change** (per plan reviewer guidance): Replace the hardcoded allowlist with a dynamic source-of-truth derived from the filesystem, using **file-presence** rather than directory-name listing:

- For skills: `find "$_PLUGIN_ROOT/skills" -maxdepth 2 -name SKILL.md -not -path '*/shared/*' -not -path '*/ui-designer/*'`, extract the parent dir name.
- For commands: `find "$_PLUGIN_ROOT/commands" -maxdepth 1 -name '*.md'`, extract the basename minus `.md`.
- Union both sets via `sort -u`; assign to `DSO_SKILLS`.
- **Fail-loud**: assert both sets are non-empty before assigning (an empty allowlist would silently pass every typo).

**Coupling check (mandatory before merge)**: `plugins/dso/scripts/qualify-skill-refs.sh` sources `check-skill-refs.sh` per the latter's line 30-31 comment. Before merging, confirm that switching `DSO_SKILLS` from a constant string to a subshell-computed value still produces a shell variable that survives the source. Run both `test-check-skill-refs.sh` and `test-qualify-skill-refs.sh` before and after.

**Out of scope** (per reviewer): the proposed bonus header comments in `commands/commit.md` and `commands/end.md` are dropped. CLAUDE.md rule 10 already governs orchestrator-invocation prohibition; additional in-file warnings would be redundant churn.

**Validation**:
- `tests/scripts/test-check-skill-refs.sh` and `tests/scripts/test-qualify-skill-refs.sh` PASS.
- Add a new fixture-based assertion: introduce a typo `/dso:nonexistent` in a temp file and confirm `check-skill-refs.sh` flags it. Then introduce `/dso:create-bug` (real skill currently missing from allowlist) and confirm it passes.

**Risk**: A skill directory created without a `SKILL.md` would be excluded (correct). A skill with a non-standard `SKILL.md` filename (e.g., `SKILL.MD`) would be silently excluded — acceptable trade for the simpler invariant.

### C.2 — Fix CLAUDE.md deprecated config keys (R5)

**Files**:
- `CLAUDE.md` line 60 (Config keys bullet)
- `.claude/dso-config.conf` line 102

**Change to CLAUDE.md:60**:
- Remove the three deprecated names (`merge.strategy`, `enforcement.strategy`, `worktree.isolation_enabled`) from the inline list.
- Add `dso.workflow` to the list with a one-line description: "(consolidated workflow knob — replaces legacy `merge.strategy`, `enforcement.strategy`, `worktree.isolation_enabled`)".

**Change to `.claude/dso-config.conf:102`**:
- Comment out the line: `# worktree.isolation_enabled=true  # DEPRECATED — consolidated into dso.workflow=ci-pr (line 83)`

**Validation**:
- `grep -n "merge.strategy\|enforcement.strategy\|worktree.isolation_enabled" CLAUDE.md` → only inside the parenthetical "replaces legacy" note.
- `bash plugins/dso/scripts/read-config.sh worktree.isolation_enabled` → returns empty (or default), no exit-1.
- Sprint behavior unchanged in this repo: `dso.workflow=ci-pr` is the active knob.

**Risk**: Negligible — sentinel lockout isn't active yet; this just removes misleading documentation and aligns the host conf file with the deprecated-comment style.

### C.3 — Replace `make test-unit-only` in agent-executed prompts (R8)

**Files** (4 violations across 3 files):
- `plugins/dso/docs/ACCEPTANCE-CRITERIA-LIBRARY.md` lines 51-52, 113
- `plugins/dso/skills/sprint/prompts/task-execution.md` lines 78, 83
- `plugins/dso/docs/workflows/prompts/review-fix-dispatch.md` line 165

**Changes (per plan reviewer guidance — NOT a uniform 1:1 substitution)**:

- **`ACCEPTANCE-CRITERIA-LIBRARY.md:51-52, 113`** — substitute `make test-unit-only` with `.claude/scripts/dso test-batched.sh --runner=pytest --test-dir=<dir>` (or direct `$PLUGIN_SCRIPTS/test-batched.sh` if shim routability is unconfirmed at merge time). Add a footnote citing CLAUDE.md rule 19.
- **`sprint/prompts/task-execution.md:78`** — substitute as above.
- **`sprint/prompts/task-execution.md:83`** — **keep `make test-unit-only`** in the `git stash / git stash pop` diagnostic; add a parenthetical: "(if invoking from the Bash tool, replace with `.claude/scripts/dso test-batched.sh --runner=pytest --test-dir=<dir>` — raw `make` may exceed the ~73s ceiling)". Rationale: the surrounding diagnostic depends on identical-invocation semantics across the stash/unstash boundary; mechanical substitution could change failure detection.
- **`workflows/prompts/review-fix-dispatch.md:165`** — substitute as above; preserve the `> "$TEST_LOG"` redirect (`test-batched.sh` is streamable).

**Pre-merge verification**: confirm `test-batched.sh` is shim-routable via `.claude/scripts/dso test-batched.sh --help`. If not, use the direct `$PLUGIN_SCRIPTS/test-batched.sh` form.

**Do NOT change** (verified non-violations):
- `MIGRATION-TO-PLUGIN.md:35, 172` (human-targeted)
- `PRE-COMMIT-TIMEOUT-WRAPPER.md:91` (runs inside 120s wrapper)
- All config files, `validate.sh`, `validate-phase.sh`, schema definitions (config strings, not invocation prescriptions)

**Validation**:
- `grep -rn "make test-unit-only" plugins/dso/skills/sprint/prompts/ plugins/dso/docs/workflows/prompts/ plugins/dso/docs/ACCEPTANCE-CRITERIA-LIBRARY.md` → no matches.
- The replacement command must be executable via the Bash tool within the ceiling — `test-batched.sh` is purpose-built for that.

**Risk**: Agents that copy-paste the AC `Verify:` line into a ticket and run it via Bash tool will now succeed (`test-batched.sh` returns within ceiling) where they previously timed out. Existing tickets carrying the old `make test-unit-only` AC text don't update retroactively — that's an acceptable rate of drift.

**PR-C acceptance**:
- All three grep checks pass.
- New allowlist-regeneration logic in `check-skill-refs.sh` flags a known-typo fixture.
- `bash plugins/dso/scripts/read-config.sh worktree.isolation_enabled` returns empty.

---

## Order of operations

1. **PR-A first** — R3 is broken-in-production today; R4 doc fix touches CLAUDE.md; R2 ships broken hooks. All share the story-branch invariant theme.
2. **PR-B next** — contract+script reconciliation; independent of PR-A.
3. **PR-C last** — three loosely-related doc edits; lowest urgency.

All three PRs are individually small (<200 LOC total each) and independently revertible.

## Plan Review (opus subagent, 2026-05-19)

A Principal-Engineer review pass was run against each sub-item. Verdicts:

| Item | Finding | Verdict | Note |
|---|---|---|---|
| A.1 | R3 — create-story-branch.sh stdout | APPROVE | Reviewer expanded test-file scope to 4 sites (lines 95, 178, 208, 238) — integrated above. |
| A.2 | R4 — CLAUDE.md story-merge invariant | APPROVE | Zero behavioral risk. |
| A.3 | R2 — onboarding dispatchers/ paths | APPROVE | Fail-loud failure mode; no silent regression. |
| B.1 | R6 — verifier-verdict exit code | APPROVE | New test required (existing test asserts current wrong behavior). |
| B.2 | R7 — suggestion in severity enum | APPROVE | Pure contract↔producer reconciliation. |
| C.1 | R1 — check-skill-refs.sh allowlist | **MODIFY** | Use file-presence (`-name SKILL.md`) over directory listing; verify qualify-skill-refs.sh source-coupling; drop bonus header-comment churn. **Integrated above.** |
| C.2 | R5 — deprecated config keys | APPROVE | Slight maintainability win for future sentinel-on migration. |
| C.3 | R8 — make test-unit-only sites | **MODIFY** | Not a uniform substitution: `task-execution.md:83` keeps `make test-unit-only` (git-stash diagnostic depends on invocation parity) with parenthetical guidance; verify `test-batched.sh` shim routability pre-merge. **Integrated above.** |

Overall reviewer assessment: PR sequencing is sound, no cross-PR ordering constraints, no fix introduces new coupling or failure modes. B.1 and C.1 are structural improvements (durably reduce future drift); others are tactical doc/path fixes that are net-positive.
