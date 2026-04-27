# Proposed Mitigations — 2026-04-26

## Scope and design principle

This document proposes mitigations for the gaps validated in `docs/pattern-gap-review-4-26.md`. The design principle is **defense in depth across the four DSO workflow phases**:

1. **Planning** — `/dso:brainstorm` → `/dso:preplanning` → `/dso:implementation-plan`
2. **Execution** — `/dso:sprint` (epic/story-driven) and `/dso:fix-bug` (bug-driven)
3. **Validation** — `/dso:review` (sub-agent), pre-commit hooks, test gates
4. **Integration** — CI workflows, `validate.sh --ci`, release gate

Each gap gets at least three mitigations distributed across phases so that a single failure mode is caught at multiple checkpoints. Mitigations are designed to be additive: any one of them would reduce defect leakage, and the combination produces redundancy without hard coupling.

A mitigation is "successful" if it (a) names a specific enforcement point, (b) has a clear input/output contract a reviewer can verify, and (c) closes the path by which the cited tickets reached `main`.

---

## G1 — No hermeticity gate in pre-commit

**Cited evidence**: 18 syntactic-only hooks; `check-portability.sh` only flags `/Users/`, `/home/`. Failures: `fe45-0b58`, `09d8-11f0`, `82ad-7bb3`, `97a7-4504`, `a40e-ab52` (Pattern 1).

### G1-M1 (Validation phase) — `check-hermeticity.sh` pre-commit hook

Add a new pre-commit hook that AST/regex-scans staged `.sh` files for: (a) any reference to `$CLAUDE_PLUGIN_ROOT` not preceded by an `:-` default expansion or a `[[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]` guard, when the script declares `set -u` or `set -euo pipefail`; (b) `declare -A` usage in any script under directories the platform matrix targets (initially: `plugins/dso/scripts/`, `plugins/dso/hooks/`, `.claude/scripts/`); (c) `BASH_SOURCE` resolution that does not flow through `readlink -f` or equivalent. Emit per-file diagnostics with the exact remediation string. Add the hook to `.pre-commit-config.yaml` between `shellcheck` and `pre-commit-review-gate`.

**Why this works**: every cited Pattern 1 ticket would have been blocked at staging time. The hook is purely static (no execution), so it has zero runtime cost and no flakiness. The `declare -A` rule is safe because the platform matrix is the binding constraint — scripts that genuinely target bash 4+ can opt out via a `# bash4-only:` comment that the hook recognizes (parallel to `# isolation-ok:`).

### G1-M2 (Validation phase) — Reviewer rubric items for hermeticity

Add to `reviewer-delta-deep-correctness.md` and `reviewer-delta-deep-hygiene.md` a checklist item: *"For each `.sh` file in the diff that imports any `$CLAUDE_PLUGIN_ROOT`, `$REPO_ROOT`, or `$BASH_SOURCE`-derived path: confirm the variable is either guarded with a `:-` default or asserted at script entry. If `set -u` is in effect and the variable can be unbound when invoked from pre-commit's symlink chain, raise a `correctness` finding at severity 2."* This is the second ring of defense behind G1-M1: the hook is mechanical and may have false negatives on novel constructs; reviewer judgment closes the gap.

**Why this works**: G4 verification confirmed reviewer rubrics currently have no such item. Adding one named, scoped checklist item turns "a thing reviewers might notice" into "a thing reviewers must check." The pairing with G1-M1 means a regression must defeat *both* a static check and an LLM reviewer to land.

### G1-M3 (Integration phase) — Hermetic CI smoke job

Add a new CI workflow `hermetic-smoke.yml` (or extend `portability-smoke.yml`) that runs `validate.sh --ci` inside an `env: { CLAUDE_PLUGIN_ROOT: "" }` block, with explicit `unset CLAUDE_PLUGIN_ROOT` in the run step, fresh `HOME=$(mktemp -d)`, and minimal `PATH=/usr/bin:/bin`. Trigger on every PR. Fail the PR if any test that passes locally fails in this hermetic environment.

**Why this works**: G9 verification confirmed `ci.yml` currently inherits `CLAUDE_PLUGIN_ROOT` and never exercises the unset-variable code path. This mitigation makes the unset case a first-class CI leg. It catches the residual class of hermeticity bugs that escape G1-M1 (regex blind spots) and G1-M2 (reviewer misses).

---

## G2 — No cross-runner equivalence gate

**Cited evidence**: Four runners (`bash-runner.sh`, `suite-engine.sh`, `run-hook-tests.sh`, `validate.sh`) drift on RED markers, command_hash, scope, timeout. Failures: `7225-7708`, `bf39-4494`, `e2b6-1059`, `e8a9-136f` (Pattern 2).

### G2-M1 (Validation phase) — Runner-equivalence contract test

Create `tests/runners/test-runner-equivalence.sh` that takes a fixed corpus of test files (a known-passing set, a known-RED-marker set, a known-skipping set) and runs each through every runner declared in `plugins/dso/scripts/runners/`. Assert all runners produce the same pass/fail/skip classification for each file. Add the test to `validate.sh --ci` and to a new pre-commit hook `runner-touch-check.sh` that fires only when the diff touches a file under `plugins/dso/scripts/runners/`.

**Why this works**: every cited Pattern 2 ticket would have failed this contract test. The hook scope (only when runner code changes) keeps cost zero on most commits. The corpus is small and stable; maintenance burden is bounded.

### G2-M2 (Planning phase) — Implementation-plan task template for runner changes

Update `plugins/dso/skills/implementation-plan/SKILL.md` to add a templated checklist item that fires whenever the planned diff touches `plugins/dso/scripts/runners/`: *"Task X.Y: Update runner-equivalence corpus in `tests/runners/` to cover the new behavior, and add a RED test asserting both bash-runner.sh and suite-engine.sh produce identical classification. This task is mandatory and cannot be merged with another task."* This forces the equivalence test to be authored as part of the original change, not after a CI failure.

**Why this works**: G2 is a sustained drift problem because runner updates are reactive. Anchoring the equivalence test inside the implementation plan forces the author to think about the contract before writing the code. Combined with G2-M1, the gap is closed at both authoring and merging.

### G2-M3 (Validation phase) — Reviewer rubric item for runner changes

Add to `reviewer-delta-standard.md` and `reviewer-delta-deep-correctness.md`: *"If the diff touches `plugins/dso/scripts/runners/`, `validate.sh`, or `run-hook-tests.sh`: confirm the change includes a corresponding update to the runner-equivalence test corpus AND a paired update to every other runner that shares the affected semantic (RED markers, command_hash, scope, timeout). Missing pair = `correctness` finding at severity 2."*

**Why this works**: G4 verification confirmed reviewer rubrics have no cross-runner item. This closes the path where a runner change ships solo because the author forgot the sibling.

---

## G3 / Pattern 5 — Agent self-attestation of "graceful degradation"

**Cited evidence**: Ticket `3dae-af1a` (open) — agent skipped scrutiny pipeline by self-narrating a "logged rationale." Reframed from G3 (per `pattern-gap-review-4-26.md` Part 3): the failure is not the prose, it is the absence of an external check on the agent's degradation claim.

### G3-M1 (Planning phase) — Mandatory degradation receipt

Modify every skill phase that contains a "graceful degradation" or "safe fallback" clause (`brainstorm/phases/approval-gate.md:4`, `brainstorm/SKILL.md:441`, `preplanning/SKILL.md:380,397`, `implementation-plan/SKILL.md:480`, etc.) to require: *"Degradation must be recorded by writing a `degradation-receipt.json` in the worktree, containing `{phase, step, reason, attempted_command, error_output, timestamp}`. The next phase MUST refuse to proceed if a receipt is present and the user has not acknowledged it."* Add a pre-commit hook `degradation-receipt-check.sh` that fails when an unacknowledged receipt is present in the worktree.

**Why this works**: ticket `3dae-af1a` shows the agent satisfied the "logged rationale" requirement by writing prose into its own narration. A receipt file is *external* state — the agent cannot self-narrate its existence; it must execute a write, and a downstream gate can verify the write happened. This converts "log a rationale" from agent-internal compliance to externally checkable evidence.

### G3-M2 (Execution phase) — Sprint-level degradation gate

Add to `plugins/dso/skills/sprint/SKILL.md` a Phase 0 check: *"Before starting any batch, list `*.degradation-receipt.json` files in the worktree. For each unacknowledged receipt, halt and present to the user: receipt details + the question 'Proceed with this skipped step? (y/N)'. Do not auto-acknowledge."* This makes degradations visible at the next workflow boundary instead of compounding silently.

**Why this works**: in the `3dae-af1a` case, the brainstorm produced a `brainstorm:complete` epic with no scrutiny receipts. A sprint-phase check would surface that the epic carries an unacknowledged degradation before any code is written. This is a workflow-boundary checkpoint complementing G3-M1's intra-skill check.

### G3-M3 (Validation phase) — Completion-verifier check for receipts

Extend `dso:completion-verifier` (per `CLAUDE.md` rule "Always Do These #20") to refuse epic/story closure when degradation receipts exist for the work item being closed. The verifier already has authority to block closure; add receipt enumeration to its checklist.

**Why this works**: completion-verifier is already the canonical "is this really done" agent. Adding receipt enumeration costs ~10 lines of prompt and gives a third independent gate. An epic that survives all three (G3-M1 intra-skill, G3-M2 sprint boundary, G3-M3 closure) cannot ship with an unacknowledged degradation.

---

## G4 — Reviewer rubrics lack hermeticity / cross-runner / cross-platform items

**Cited evidence**: grep of four reviewer delta prompts confirms missing items (Patterns 1, 2, 4).

### G4-M1 (Validation phase) — Add platform-axis checklist to deep-correctness

Add to `reviewer-delta-deep-correctness.md` a "Platform & hermeticity" sub-section with explicit items: env-var guarding (covered by G1-M2), bash 3.2 incompatibilities (`declare -A`, `${var^^}`, `mapfile`/`readarray`, `[[ =~ ]]` capture groups, `coproc`), SIGPIPE-safety on pipefail (covered by G12-M1), `BASH_SOURCE` resilience under symlink. Each item names the bug class and the cited ticket so the reviewer has concrete grounding.

**Why this works**: G4 verification confirmed the reviewer prompts are silent on these. Reviewers cannot flag what their rubric does not name. The named items also serve as documentation for future contributors.

### G4-M2 (Validation phase) — Cross-platform check in deep-verification

Add to `reviewer-delta-deep-verification.md`: *"For every test added or modified: assert the test runs in (a) bash 3.2 (`bash --version` returns 3.x), (b) clean env (`unset CLAUDE_PLUGIN_ROOT HOME`), (c) under both bash-runner.sh and suite-engine.sh. Tests that depend on bash 4+ syntax must declare `# requires-bash4` and be excluded from the platform matrix."* The reviewer agent verifies the declaration is consistent with the test body.

**Why this works**: this couples test writing to platform reality. Most tests today implicitly assume bash 4 + populated env; this rubric item forces explicit acknowledgment.

### G4-M3 (Planning phase) — Implementation-plan injects rubric flags

Update `plugins/dso/skills/implementation-plan/SKILL.md` so that when a task is classified as touching shell hooks, runners, or platform-sensitive scripts, the task spec auto-includes the reviewer flags `correctness:hermeticity`, `correctness:platform`. The reviewer agent reads these flags and applies the corresponding rubric items at higher severity.

**Why this works**: this binds the rubric to the change context, so the relevant items always fire when relevant. It avoids the "reviewer skimmed past" failure mode by making the rubric items orchestrator-mandated rather than reviewer-discretionary.

---

## G5 — REVIEW-DEFENSE and `# isolation-ok:` allow subjective override

**Cited evidence**: `reviewer-base.md:209-220` confirmed verbatim. `reviewer-delta-standard.md:35` confirms `# isolation-ok:` annotation has no external validation.

### G5-M1 (Validation phase) — Defense requires linked artifact

Modify the REVIEW-DEFENSE protocol to require that the defense comment cite a verifiable artifact by URL or path (a test, an ADR, a closed ticket, a documented pattern in CLAUDE.md). Reviewers are instructed to *not* downgrade a finding when the defense cites no artifact, regardless of how persuasive the prose. Add a pre-commit check `check-review-defense-citations.sh` that scans for `# REVIEW-DEFENSE:` comments and verifies each contains at least one path/URL/ticket-ID token.

**Why this works**: G5 verification confirmed the current acceptance criteria ("verifiable artifacts") are subjective. Requiring an actual citation that a script can pattern-match makes the requirement enforceable. Defenses without citations remain visible in the code but cannot lower severity.

### G5-M2 (Validation phase) — Two-reviewer rule for downgrades

When a deep-tier review downgrades a finding via REVIEW-DEFENSE, dispatch a second reviewer (`dso:code-reviewer-deep-arch` or a peer specialist) to independently evaluate the same defense without seeing the first reviewer's verdict. If the second reviewer disagrees, the higher severity wins. Implement as a step inside `REVIEW-WORKFLOW.md` triggered by the presence of `severity_lowered: true` in `reviewer-findings.json`.

**Why this works**: this directly addresses the "single reviewer self-overrides" failure mode. The second reviewer is structurally analogous to the blue-team filter — its sole job is to challenge a downgrade, not to re-do the original review.

### G5-M3 (Execution phase) — `# isolation-ok:` registry

Replace inline `# isolation-ok:` comments with entries in a tracked registry file (`plugins/dso/config/isolation-exceptions.yaml`) requiring `{file, reason, approved_by, ticket_id, expires_on}` fields. Comments in code reduce to `# isolation-ok: see registry`. The pre-commit hook reads the registry and refuses commits whose isolation-ok references have expired or lack approver attestation.

**Why this works**: an inline comment is uncheckable; a registry entry is structured data with explicit fields a hook can validate. The `expires_on` field forces periodic re-justification, preventing exceptions from becoming permanent by inertia.

---

## G6 — Prior-art search excludes single-file fixes

**Cited evidence**: `prior-art-search.md:79-88` excludes "single-file logic fixes." Recurrence chain: `09d8-11f0` → `fe45-0b58` → `82ad-7bb3` → `97a7-4504` (Pattern 3).

### G6-M1 (Execution phase) — Antipattern ratchet step in fix-bug

Add to `plugins/dso/skills/fix-bug/SKILL.md` a mandatory post-fix step (before commit): *"Extract the antipattern from the fix as a regex or `sg` AST query (e.g., `\$CLAUDE_PLUGIN_ROOT[^:-]` for the unguarded-env-var pattern). Run the query across the entire codebase. If matches exist outside the fixed file: open follow-up bug tickets for each match cluster, OR include the matches in the current fix scope, OR add a `# antipattern-ok: <reason>` annotation to each. Commit message must include the antipattern query and the match count."*

**Why this works**: the recurrence chain is the empirical proof of this gap. Mechanizing the tree-wide scan converts "did the author think to look elsewhere?" into a documented checklist step. Each of the four cited tickets would have been collapsed into a single fix had this step existed.

### G6-M2 (Validation phase) — Pre-commit antipattern-ratchet hook

Maintain a registry (`plugins/dso/config/known-antipatterns.yaml`) of regexes/AST queries discovered via G6-M1 over time. The pre-commit hook `check-known-antipatterns.sh` runs every registered query against staged files and fails on a match. New entries are added as fixes land; the registry is append-only and acts as a collective ratchet.

**Why this works**: G6-M1 catches *new* antipatterns at first occurrence; G6-M2 prevents *known* antipatterns from regressing. Combined they form a closing-ratchet: every Pattern 3 instance ever observed becomes mechanically blocked from recurring.

### G6-M3 (Planning phase) — Brainstorm/preplanning antipattern audit

When `/dso:brainstorm` or `/dso:preplanning` produces an epic that touches a file class associated with a known antipattern (e.g., shell hooks → CLAUDE_PLUGIN_ROOT, runners → semantic drift), inject a pre-emptive task: "Audit for `<antipattern>` across all files in scope before implementation begins." This shifts the audit left from fix-bug (reactive) to planning (proactive).

**Why this works**: by the time a fix-bug skill runs, the antipattern has already shipped. Pulling the check into planning catches the case where new code is written that would *introduce* the antipattern in additional locations. Together with G6-M1 (post-fix scan) and G6-M2 (pre-commit hook), this gives planning, execution, and validation coverage.

---

## G7 — Release-gate is the de facto integration test

**Cited evidence**: 16 of 22 closed bugs detected at `validate.sh --ci` precondition #8 in `scripts/release.sh`. Pre-commit hooks are per-file.

### G7-M1 (Validation phase) — Post-commit `validate.sh --ci` background check

Add a post-commit hook (or `.git/hooks/post-commit`) that triggers `validate.sh --ci` in the background after every commit on a worktree branch, with results piped to a notification channel (terminal banner, file in `~/.claude/logs/`). Failures do not block the commit (post-commit hooks cannot), but they alert the orchestrator immediately rather than at release time.

**Why this works**: this collapses the discovery latency from "release time" to "next commit." The orchestrator sees the failure and can fix it inside the same session rather than days later when releasing. The hook is non-blocking, so it doesn't introduce a slow gate; it just shifts visibility left.

### G7-M2 (Execution phase) — Sprint phase-completion gate

Add to `plugins/dso/skills/sprint/SKILL.md` a phase-completion checkpoint: *"Before transitioning from one batch of stories to the next, run `validate.sh --ci`. If it fails, do not start the next batch — fix the failure first."* This ensures regressions are caught at the boundary between batches rather than accumulating until release.

**Why this works**: sprint typically processes multiple batches per session. Without this checkpoint, a failure introduced in batch 1 can compound through batches 2-N and only surface at release. The full-suite cost (currently ~minutes) is amortized across the batch transition where the orchestrator is already context-switching.

### G7-M3 (Integration phase) — PR-level `validate.sh --ci` requirement

Configure GitHub branch protection on `main` to require a CI status check that runs `validate.sh --ci` on every PR. Combined with G9-M1 (hermetic env), this makes release-equivalent validation a *pre-merge* gate rather than a *pre-release* gate. The release gate itself (`scripts/release.sh` precondition #8) becomes a redundant safety net.

**Why this works**: this directly addresses G7's structural framing. The pre-commit gate is per-file; the release gate is full-suite but late. A PR-level full-suite gate is the missing tier between them. Required-status-check protection makes it impossible to merge a regression that the release gate would catch.

---

## G8 — Two CI workflows persistently red

**Cited evidence**: `ticket-platform-matrix.yml` 7/7 failed; `ticket-perf-regression.yml` 5/5 failed. No tracking ticket.

### G8-M1 (Integration phase) — File P1 tickets, treat as outage

File two P1 bug tickets (one per workflow) tagged `ci-infrastructure`, with the failure logs as evidence. Add to `CLAUDE.md` "Always Do These": *"When a CI workflow fails 3+ consecutive times on `main`, file a P1 ticket within 24 hours. Persistent CI red is treated as an outage, not a known-issue."* The 100% failure rate is the symptom of a process gap (silent tolerance); the rule closes the gap.

**Why this works**: the gap exists because there is no policy for "what to do when CI is persistently red." Codifying the policy + filing the immediate tickets converts tolerated red into actionable red. The rule generalizes — it prevents the same drift in other workflows.

### G8-M2 (Validation phase) — Block release on workflow health, not just last run

Extend `scripts/release.sh` precondition checklist with: *"For each workflow declared as required in `release-required-workflows.yaml`: assert the last 3 runs on `main` are all green. A single green run after a red streak is not sufficient."* This prevents the case where a flaky workflow happens to pass once and unblocks a release that should be held.

**Why this works**: release.sh currently checks "CI green" as a snapshot. Persistent failures are masked by single intermittent passes. Requiring a streak is a small change with a high signal-to-noise improvement.

### G8-M3 (Integration phase) — Promote `ticket-platform-matrix.yml` to PR trigger

Remove the path filter from `ticket-platform-matrix.yml`'s pull_request trigger so that *every* PR runs the matrix legs (Linux bash 4, macOS bash 3.2, Alpine BusyBox). This makes platform compatibility a pre-merge gate. (Verification corrected the doc's claim that this workflow is push-only — it does have a PR trigger, but the path filter is so narrow it never fires for most relevant changes.)

**Why this works**: G8 + G1 share root cause (no platform-axis enforcement). This mitigation makes the platform matrix a binding pre-merge constraint. Combined with G8-M1 (file the tickets to fix the failures) and G8-M2 (release-streak requirement), platform regressions cannot ship.

---

## G9 — CI test runs are not hermetic

**Cited evidence**: `ci.yml` has no `env:` block unsetting `CLAUDE_PLUGIN_ROOT`; `validate.sh:87-88` fallback never exercised.

### G9-M1 (Integration phase) — Hermetic env block in all CI workflows

Add to every CI workflow that runs DSO scripts a top-level `env:` block: `{ CLAUDE_PLUGIN_ROOT: "", HOME: "/tmp/ci-home", PATH: "/usr/local/bin:/usr/bin:/bin" }`. Each `run:` step explicitly `unset CLAUDE_PLUGIN_ROOT` before invoking scripts. Add a workflow-lint script (`tools/lint-workflows.sh`) that asserts every `.github/workflows/*.yml` that invokes a `dso` script declares the hermetic env block.

**Why this works**: this is the direct fix for G9's substantive claim. Combined with G1-M3 (hermetic-smoke leg), this exercises the unset-variable code path on every CI run, surfacing Pattern 1 regressions immediately.

### G9-M2 (Validation phase) — `validate.sh --ci` runs hermetically locally

Modify `validate.sh --ci` to internally `unset CLAUDE_PLUGIN_ROOT` (and other inheritable session vars) before delegating to test runners. This makes the local `--ci` invocation behaviorally equivalent to the hermetic CI run, eliminating the "passes locally, fails in CI" class.

**Why this works**: a tight local-vs-CI parity loop is the most effective developer-time defense against Pattern 1. By making `--ci` mean "what CI does," authors get instant feedback rather than discovering the divergence at PR time.

### G9-M3 (Execution phase) — fix-bug requires hermetic repro

Update `plugins/dso/skills/fix-bug/SKILL.md` Step 5 (RED test) to require the failing test be reproducible in a hermetic shell: *"The RED test must fail under `env -i bash -c 'unset CLAUDE_PLUGIN_ROOT; <test command>'`. If it does not, the test is environmental noise and the bug needs reframing."* This forces hermeticity into the bug-fix loop, not just the validation loop.

**Why this works**: many Pattern 1 bugs were originally reproducible only in CI because the local repro was contaminated. Requiring hermetic repro at fix-bug time means every Pattern 1 fix carries a hermetic test, and the test corpus naturally accumulates hermetic coverage over time.

---

## G10 — Skill content has no anti-drift gate

**Cited evidence**: `ce2bcbde94` had to restore lost behavioral guidance. Recurring memory entries about agent dispatch corrections.

### G10-M1 (Validation phase) — Required-section manifest

Create `plugins/dso/config/skill-section-manifest.yaml` that lists, per skill file, the section headings that must be present (e.g., `brainstorm/SKILL.md` must have `## Phase 0`, `## Phase 1`, ..., `## Approval Gate`). Pre-commit hook `check-skill-sections.sh` parses staged skill files and fails if any required heading is missing.

**Why this works**: the `39b0-130d` / `ce2bcbde94` failure was a section-deletion regression. A manifest + structural check would have blocked the original deletion commit. Section names are stable contracts; their absence is a strong signal of unintended deletion.

### G10-M2 (Validation phase) — Reviewer rubric item for skill diffs

Add to `reviewer-delta-deep-hygiene.md`: *"If the diff modifies a file under `plugins/dso/skills/`: confirm no behavioral guidance, dispatch instruction, or hard-gate clause was removed without explicit replacement. Removed lines containing 'MUST', 'NEVER', 'dispatch', or 'gate' require justification in the commit message OR in a `# REMOVED:` block in the diff."*

**Why this works**: section-presence (G10-M1) catches whole-section deletion; line-level deletion of guidance within a section needs reviewer judgment. The keyword-driven flag focuses reviewer attention on the high-risk lines.

### G10-M3 (Planning phase) — Skill edits route through implementation-plan

Add to `CLAUDE.md` "Always Do These": *"Edits to files under `plugins/dso/skills/` or `plugins/dso/agents/` must originate from a planned task with explicit success criteria naming the behavior change. Direct skill edits without a parent ticket are blocked at commit time by `check-skill-edit-source.sh`, which verifies the commit message references a ticket ID whose description mentions skill modification."*

**Why this works**: drift compounds when skill edits are casual. Forcing every skill edit through a ticket creates an audit trail and a deliberate moment for the author to consider whether the edit removes behavior. Combined with G10-M1 (manifest) and G10-M2 (reviewer), unintentional drift becomes structurally hard.

---

## G11 — Config keys decoupled from documentation

**Cited evidence**: ticket `a190-d780` (`commands.test_dirs` undocumented). Note: `93f9-de68` rejected as misclassified (per review doc Part 3).

### G11-M1 (Validation phase) — Config-key cross-reference hook

Add a pre-commit hook `check-config-key-docs.sh` that: (a) parses all `KEY=VALUE` lines in `dso-config.conf` and example configs, (b) parses `plugins/dso/docs/CONFIGURATION-REFERENCE.md` for documented keys, (c) fails if any key in the config is not mentioned in the doc, or if any key in the doc no longer appears in any config or script. Run on every commit that touches either file.

**Why this works**: ticket `a190-d780` was caught by `ci/test-config-keys-documented.sh`, which suggests CI infrastructure exists but is not in the pre-commit chain. Promoting it to pre-commit shifts the catch left from CI to staging.

### G11-M2 (Planning phase) — Implementation-plan task template for config keys

Update `plugins/dso/skills/implementation-plan/SKILL.md` to include, for any task that adds a config key: a paired sub-task *"Document the new key in `CONFIGURATION-REFERENCE.md` with description, type, default, scope, and example. This sub-task is required and cannot be skipped."* Without the paired sub-task, the implementation-plan output fails its own self-review.

**Why this works**: G11 is fundamentally an authoring-time omission. Embedding the doc step in the plan prevents the omission rather than catching it post-hoc. The pairing with G11-M1 means a forgetful author still gets caught at commit.

### G11-M3 (Validation phase) — Reviewer rubric item

Add to `reviewer-delta-standard.md`: *"If the diff adds or modifies a key in `dso-config.conf` or any `*.conf`: confirm the matching entry in `CONFIGURATION-REFERENCE.md` exists and reflects the change. Missing or stale doc = `maintainability` finding at severity 3."*

**Why this works**: closes the case where the hook (G11-M1) has a false negative due to config syntax variation. Three rings: planning (G11-M2), commit (G11-M1), review (G11-M3).

---

## G12 — SIGPIPE / pipefail antipattern has no static-detection gate

**Cited evidence**: 42 files in `plugins/dso/` still contain `echo … | grep -q`; `pre-commit-review-gate.sh:259` is a live instance in a hook (Pattern 4).

### G12-M1 (Validation phase) — Pre-commit static check

Add a pre-commit hook `check-pipefail-grep.sh` that scans staged `.sh` files for the pattern `echo .* \| grep -q` (and equivalent `printf .* \| grep -q`) under any script with `set -o pipefail` or `set -euo pipefail`. Fail with a remediation message: "Use `grep -q PATTERN <<< \"\$VAR\"` here-string instead — see ticket `e241-41b2`." Add the existing 42 files as a known-baseline (similar to G6-M2's antipattern registry) so the hook fires only on *new* instances; pre-existing files are tracked for deferred remediation.

**Why this works**: G12 is exactly the case where a one-shot 26-file remediation didn't converge. A standing static check converts "did the author remember?" into a mechanical block. The baselining approach lets the hook ship today without requiring 42 simultaneous fixes.

### G12-M2 (Execution phase) — Reviewer rubric item

Add to `reviewer-delta-deep-correctness.md`: *"For every `echo … | grep …` or `printf … | grep …` construct in the diff: confirm the script does not have `pipefail` set, OR the construct uses a here-string (`<<<`) instead of a pipe. Pipe-to-grep under pipefail is a SIGPIPE risk on Linux (ticket `e241-41b2`, `999e-cf69`)."*

**Why this works**: G12-M1 catches mechanical occurrences; the reviewer item catches creative variants the regex misses.

### G12-M3 (Integration phase) — Linux-only CI smoke test for pipefail

Add a CI step (or extend `hermetic-smoke.yml`) that runs the test suite with `BASH_OPTS="-eo pipefail"` exported and on Linux only. Failures here surface SIGPIPE divergences that macOS local development cannot reproduce.

**Why this works**: G12 is Pattern 4 — Linux-strict, macOS-lenient. A Linux-strict CI leg makes the divergence visible at PR time. Combined with G12-M1 (commit-time block) and G12-M2 (reviewer flag), the antipattern is caught at three independent points.

---

## Cross-cutting summary

| Workflow phase | Mitigations contributed |
|---|---|
| **Planning** (brainstorm → preplanning → implementation-plan) | G2-M2, G3-M3 (via verifier), G4-M3, G6-M3, G10-M3, G11-M2 |
| **Execution** (sprint, fix-bug) | G3-M2, G6-M1, G7-M2, G9-M3, G12-M2 |
| **Validation** (review, pre-commit, test gates) | G1-M1, G1-M2, G2-M1, G2-M3, G3-M1, G4-M1, G4-M2, G5-M1, G5-M2, G5-M3, G6-M2, G7-M1, G9-M2, G10-M1, G10-M2, G11-M1, G11-M3, G12-M1 |
| **Integration** (CI, release) | G1-M3, G7-M3, G8-M1, G8-M2, G8-M3, G9-M1, G12-M3 |

**Defense-in-depth verification**: every validated gap has at least one mitigation in *each* of (Planning OR Execution) and (Validation OR Integration), ensuring no gap relies on a single point of enforcement. Bug-fix workflow coverage: G3-M2 (sprint, but generalizes), G6-M1 (fix-bug specifically), G9-M3 (fix-bug specifically), and all Validation-phase mitigations apply equally to fix-bug commits because they fire at the pre-commit/review boundary regardless of the originating workflow.

**Mitigation interaction notes**: G1-M1 + G1-M2 + G1-M3 are designed to be ordered — the static hook is cheapest, the reviewer rubric catches the residual, and the CI hermetic leg catches the long tail. G3's three mitigations work as cascading checkpoints (intra-skill receipt → sprint-boundary check → closure-time verifier) so an unacknowledged degradation must defeat three independent gates. G6's three mitigations form a closing ratchet across planning, execution, and validation. G7's three mitigations collectively replace "release time" with "commit time / batch boundary / PR time" as the integration-test horizon.

**Rejected mitigation ideas** (and why):
- *"Rewrite all skill prose to remove 'graceful degradation' wording"* — rejected because the review doc Part 3 establishes that 6 of 8 cited clauses are reasonable controlled fallbacks; mass rewrite would harm correctness without reducing exploitation. The receipt-based G3 mitigations target the actual mechanism.
- *"Block all `--no-verify` invocations more aggressively"* — already covered by Layer 2 of the review gate (`review-gate.sh` PreToolUse hook); not a gap.
- *"Mandate code review for every plugin/dso/ edit"* — already covered by `/dso:review` integration with `/dso:commit`; not a gap.
