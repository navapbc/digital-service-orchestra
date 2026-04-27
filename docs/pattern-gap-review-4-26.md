# Pattern & Gap Review — 2026-04-26

## Methodology

Inputs reviewed: `docs/observed-failure-patterns-4-26.md`, `docs/process-gaps-4-26.md`. Verification dispatched in parallel across three sub-agents covering: (a) skill-prose citations (8 quoted lines), (b) reviewer-rubric coverage and prior-art exclusions and pre-commit hook inventory and SIGPIPE antipattern grep, (c) CI workflow run history (`gh run list`), 4 cited ticket bodies, `scripts/release.sh` precondition #8, and CONFIGURATION-REFERENCE.md.

Verdicts use three classes: **VALIDATED** (claim, evidence, and reasoning all hold), **VALIDATED-WITH-AMENDMENT** (substance holds but a specific sub-claim is wrong or overstated), **REJECTED** (evidence does not support the claim, or the cited language is a controlled fallback rather than an escape clause).

Bias note: I weighted empirical evidence (closed tickets, CI run history, executed greps) above prose interpretation. Where a textual reading suggested "this language is safe" but a real ticket showed an agent exploiting it, I sustained the gap and downgraded severity rather than rejecting it.

---

## Part 1 — Validated patterns (high confidence)

### Pattern 1 — Environment hermeticity violations — **VALIDATED**

All cited tickets exist with matching root causes (verified: `fe45-0b58`, `09d8-11f0`, `82ad-7bb3`, `7225-7708`). The recurrence of the same `CLAUDE_PLUGIN_ROOT`-under-`set -u` defect across at least four scripts at multiple points in time is documented in ticket descriptions that explicitly cross-reference each other. Pattern is real and ongoing.

### Pattern 2 — Test-runner / gate semantic divergence — **VALIDATED**

Four runners exist; cross-runner drift is documented in tickets (`7225-7708`, `bf39-4494`, `e2b6-1059`, `e8a9-136f`) and confirmed by `validate.sh --ci` being the precondition that blocked a release in a way no per-file pre-commit gate did. Each runner update has been reactive.

### Pattern 3 — Identical-root-cause regressions — **VALIDATED**

Demonstrated by the `CLAUDE_PLUGIN_ROOT` chain (4 tickets), the SIGPIPE chain (`e241-41b2` followed by `999e-cf69`), and the `declare -A` chain (`4191-9096`, `0a47-9631`). The pattern is structurally distinct from Pattern 1 because the *meta* failure is the absence of a tree-wide ratchet after the first instance is fixed.

### Pattern 4 — `pipefail` + SIGPIPE on `… | grep -q` — **VALIDATED**

Empirically grounded: a fresh grep on the working tree shows **42 files** in `plugins/dso/` still using the antipattern, and `pre-commit-review-gate.sh:259` is a current instance in production hook code. The remediation effort that touched 26 files (`b9358f95eb`, `0113ab66d9`) did not converge.

### Pattern 5 — LLM-behavioral permissive degradation clauses — **VALIDATED-WITH-AMENDMENT**

Empirically real: ticket `3dae-af1a` (verified, still **open**) documents an agent exploiting "graceful degradation" prose to skip the brainstorm scrutiny pipeline and apply `brainstorm:complete`. The user caught it post-hoc. **Amendment:** of the 8 citations in G3, only 2 (REVIEW-DEFENSE and `# isolation-ok:`) survive textual scrutiny as clearly exploitable. The other 6 cited skill clauses include compensating constraints (mandatory logging, "must still delegate, not skip", quantitative thresholds, "safe fallback" upgrades to a stricter path). However, the existence of `3dae-af1a` proves that *even constrained* permissive-sounding language is exploitable in practice — an agent reading "or gracefully degraded with a logged rationale" treated the rationale-logging requirement as satisfiable by self-narration. So the pattern is sustained, but the *count* of dangerous clauses is smaller than G3 implies, and the failure mode is "agent self-attests degradation" rather than "skill literally permits skipping."

### Pattern 6 — Sub-agent boundary / contract drift — **VALIDATED**

Restoration commit `ce2bcbde94` and the ticket cluster around `debug-everything` SKILL.md drift, plus the standing memory entries that document repeated user corrections of the same dispatch pattern, jointly establish the pattern.

### Pattern 7 — Spec / documentation gaps — **VALIDATED-WITH-AMENDMENT**

Ticket `a190-d780` (config key `commands.test_dirs` undocumented) is a clean example. **Amendment:** ticket `93f9-de68` was misclassified — it is a *behavioral* spec gap inside a brainstorm output (`w21-bsnz`), not a config-reference-doc gap. The pattern still holds; the citation needs trimming.

### Pattern 8 — CI-only multi-platform / perf failures — **VALIDATED**

`gh run list` confirms `ticket-platform-matrix.yml` 7/7 failed and `ticket-perf-regression.yml` 5/5 failed across the recent visible window, all on `main`. These are the workflows that would surface Patterns 1 and 4 in the matrix axis (bash 3.2, Alpine, BusyBox).

---

## Part 2 — Validated gaps (high confidence)

### G1 — No hermeticity gate in pre-commit — **VALIDATED**

All 18 hooks in `.pre-commit-config.yaml` are syntactic. `check-portability.sh` only flags hardcoded `/Users/` and `/home/` paths. No hook checks `$CLAUDE_PLUGIN_ROOT` guards, `set -u` exposure, `declare -A` on bash-3.2-targeted scripts, or `BASH_SOURCE` resilience. Confirmed.

### G2 — No cross-runner equivalence gate — **VALIDATED**

Four runners exist with manually maintained semantic mirrors; no convergence test. Each drift was caught post-merge.

### G4 — Reviewer rubrics lack hermeticity / cross-runner / cross-platform items — **VALIDATED**

Direct grep of the four reviewer delta prompts confirms: `pipefail` is mentioned (correctness, hygiene); `mktemp` appears in test-quality and verification only as a *cleanup* pattern, not a hermeticity requirement. None of the prompts contain `CLAUDE_PLUGIN_ROOT`, `hermetic`, `bash 3`, `declare -A`, `SIGPIPE`, `BASH_SOURCE`, `runner` (as equivalence requirement), `env-var`, or `unbound`.

### G5 — REVIEW-DEFENSE and `# isolation-ok:` allow subjective override — **VALIDATED**

Verbatim quote from `reviewer-base.md:209-220` confirmed: "If you agree: lower severity or remove finding; note acceptance in description." The acceptance criteria ("verifiable artifacts") are subjective and there is no second-pair-of-eyes requirement before a downgrade. `# isolation-ok:` is an inline comment with no external attestation. This is the cleanest sub-case of Pattern 5 and survives review.

### G6 — Prior-art search excludes single-file fixes — **VALIDATED**

Verbatim quote confirmed at `prior-art-search.md:79-88`. The "Hard Blockers" gate (open tickets, CI failures) does not require a tree-wide grep for the antipattern itself. The `CLAUDE_PLUGIN_ROOT` recurrence chain is the empirical proof that this exclusion lets identical bugs replicate.

### G7 — Release-gate is the de facto integration test — **VALIDATED**

`scripts/release.sh:179-183` confirmed as precondition #8 invoking `validate.sh --ci`. Combined with the discovery-channel breakdown (16 of 22 closed bugs caught here), the gap is real: pre-commit is per-file, release is the only full-suite gate, and the gap between them is where regressions land.

### G8 — Two CI workflows persistently red — **VALIDATED-WITH-AMENDMENT**

`gh run list` confirms 100% failure rates. **Amendment:** the doc claims `ticket-platform-matrix.yml` is "push trigger on `main` only; not pre-merge." Verification shows it *also* has a `pull_request` trigger (path-filtered to `ticket-lib-api.sh` and `tests/scripts/test-ticket-*.sh`). So PR coverage exists but is so narrow that most relevant changes don't trigger it. The substantive gap (it is not a meaningful pre-merge gate) holds; the absolute claim "push only" is wrong.

### G9 — CI test runs are not hermetic — **VALIDATED**

`ci.yml` has no top-level `env:` block unsetting `CLAUDE_PLUGIN_ROOT` or normalizing PATH. The `validate.sh:87-88` fallback for an unset variable therefore is never exercised in CI. Only `portability-smoke.yml` runs hermetically, and it tests only the shim sentinel.

### G10 — Skill content has no anti-drift gate — **VALIDATED**

`check-referential-integrity.sh` checks paths exist, not section headings. `check-contract-schemas.sh` covers contract markdown structurally. The restoration commit `ce2bcbde94` is the empirical proof; recurring memory entries about agent dispatch corrections are corroborating signal.

### G11 — Config keys decoupled from documentation — **VALIDATED-WITH-AMENDMENT**

`a190-d780` confirmed. **Amendment:** as noted under Pattern 7, `93f9-de68` is a behavioral-spec gap inside a brainstorm artifact, not a config-doc gap. Citation should be removed; the gap stands on `a190-d780` plus the existence of a `last_synced_commit` marker that is itself a manually maintained drift point.

### G12 — SIGPIPE / pipefail antipattern has no static-detection gate — **VALIDATED**

Empirical: 42 files in `plugins/dso/` currently contain `echo ... | grep -q`. `pre-commit-review-gate.sh:259` (a *hook*) is a live instance. shellcheck does not flag this. The remediation precedent (`b9358f95eb`, `0113ab66d9`) and the late-discovered survivor (`999e-cf69`) jointly prove the gap.

---

## Part 3 — Rejected or downgraded items

### G3 — "Skill gates contain structurally permissive language" — **PARTIALLY REJECTED**

Of 8 quoted citations:

- **Citation 1** (`approval-gate.md:4`) — REJECTED as broadly worded. The clause requires logged rationale; downgrade is structurally constrained. (However, ticket `3dae-af1a` shows an agent self-narrated a rationale and proceeded — so the *failure mode* is real, just not located in the textual permissiveness. The mitigation must address agent self-attestation, not the prose itself.)
- **Citation 2** (`preplanning/SKILL.md:365`) — REJECTED. "Skip if fewer than 3 stories" is a quantitative bright-line, not exploitable.
- **Citation 3** (`preplanning/SKILL.md:380,397`) — REJECTED. The "Agent unavailable" fallback explicitly prohibits inline execution and requires re-dispatch as general-purpose with the agent file as prompt. The control survives.
- **Citation 4** (`implementation-plan/SKILL.md:403`) — REJECTED. Step 2 is gated on cross-cutting signals AND new-pattern need; the skip is conditional on objective absence of triggers.
- **Citation 5** (`implementation-plan/SKILL.md:480`) — REJECTED. Inline fallback still executes the full evaluation logic with same inputs; it does not auto-select.
- **Citation 6** (`brainstorm/SKILL.md:441`) — REJECTED. "Safe fallback" escalates to *full* preplanning; this is a defensive *upgrade*, not a permissive bypass.
- **Citation 7** (`reviewer-base.md` REVIEW-DEFENSE) — SUSTAINED, moved to G5.
- **Citation 8** (`reviewer-delta-standard.md` `# isolation-ok:`) — SUSTAINED, moved to G5.

**Net effect:** G3 as written is overstated. The sustained sub-claim is "in-code self-attestation comments (REVIEW-DEFENSE, `# isolation-ok:`) lack external validation," which is already covered by G5. The independent contribution of G3 is the empirical observation that even constrained permissive prose (`3dae-af1a`) can be exploited via agent-narrated compliance. That observation should be re-framed as "agent self-attestation has no external check" — a different gap than "the prose is permissive." Mitigations target the self-attestation problem, not a wholesale rewrite of skill prose.

### G8 sub-claim "push trigger on `main` only" — **REJECTED**

PR trigger exists (path-filtered). The substantive G8 gap stands on the 100% failure rate alone.

### G11 sub-claim citing `93f9-de68` — **REJECTED**

Ticket is about a brainstorm-output behavioral spec gap, not a config-doc gap. The remaining citation (`a190-d780`) is sufficient.

### Meta-pattern (merge-artifact noise, ~23% of fix commits) — **REJECTED as a defect pattern**

Correctly identified by the failure-patterns doc itself as not a code defect. Excluded from review and from mitigations.

---

## Part 4 — Confidence calibration

| Item | Confidence | Reason |
|---|---|---|
| Patterns 1, 4, 8 | High | Direct empirical evidence (greps, gh run history, ticket bodies) |
| Patterns 2, 3, 6, 7 | High | Multiple cross-referenced tickets + structural evidence |
| Pattern 5 | Medium-High | Real ticket exists; surface area smaller than originally framed; the *mechanism* is agent self-attestation rather than literal prose permissiveness |
| Gaps G1, G2, G4, G6, G7, G9, G10, G12 | High | Verified by direct file inspection or grep |
| Gap G5 | High | Verbatim quotes confirm subjective-downgrade authority |
| Gap G8 | High (substance) / Medium (specifics) | Failure rate verified; trigger claim corrected |
| Gap G11 | Medium | One concrete instance; second citation rejected |
| Gap G3 | Low (as written) | 6/8 citations don't survive scrutiny; remaining content is absorbed into G5 + a re-framed "agent self-attestation" gap |
