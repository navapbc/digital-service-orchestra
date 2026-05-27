# DSO Review Remediation Plan — F-01, F-02, F-05, F-06, F-08

Plan to implement five findings from the static review of the DSO agentic
workflow plugin. **Revised** to reflect ground-truth understanding of the
actual sprint branch hierarchy, opus-subagent review feedback, and
duplication/gap analysis of the multi-PR review topology.

## Ground truth: the actual ci-pr branch topology

Verified by reading `plugins/dso/scripts/worktree-create.sh:124`,
`plugins/dso/scripts/create-sprint-draft-pr.sh`,
`plugins/dso/skills/sprint/SKILL.md:1750–1761,2498–2552`,
`plugins/dso/scripts/check-ruleset-preflight.sh`, and the actual merge
history on `main`.

```
worktree-agent-<task-id>          per-task sub-agent worktree branch
     │
     └→ PR base=worktree-YYYYMMDD-HHMMSS  (Phase F Step 5 harvest, ci-pr mode)
                ▼
worktree-YYYYMMDD-HHMMSS          THE session branch (default name)
     │
     ├→ story/<epic>/<story>     Phase E logical container; in worktree-
     │                            isolation mode the Phase F Step 18 PR is
     │                            no-diff (file movement happened in Step 5)
     │
     └→ long-lived draft PR base=main  (Phase A)
                ▼
              main
```

Three naming mismatches in the current infrastructure:

1. `INSTALL.md:136` documents the Ruleset pattern as `session-*`;
   `INSTALL.md:159` documents it as `refs/heads/session/*`. The two
   patterns differ (`-` vs `/`).
2. The Ruleset preflight (`check-ruleset-preflight.sh:142–146`) accepts
   `session-*`, `session/*`, and the `refs/heads/` variants — but
   **none** of these match the actual session branch name pattern
   `worktree-YYYYMMDD-HHMMSS` produced by `worktree-create.sh:124`.
3. `ci.yml:362–364` gates `llm-review` on `base_ref == 'main'`. The
   per-task harvest PR (head=`worktree-agent-*`, base=`worktree-*`)
   does not trigger this job; the session→main PR (head=`worktree-*`,
   base=`main`) does.

**Implication for the safety case:** every commit that reaches `main`
does so via the Phase A long-lived draft PR (head=`worktree-*`,
base=`main`). That PR triggers `llm-review` today. The KNOWN GAP cited
in `INSTALL.md:141` is real, but it describes the absence of *per-sub-
branch* review, not a path by which code reaches `main` without review.
The plan's prior framing of F-01 as "code-to-main without review"
overstated this.

## Scope

| ID   | Finding                                                                | Severity     | Est. effort  |
|------|------------------------------------------------------------------------|--------------|--------------|
| F-08 | Stale "skeleton/future task" header in `merge-to-main-pr.sh` and peers | Low-Medium   | ~1 hr        |
| F-06 | `tickets.directory` honored only partially in merge logic              | Medium       | 1–2 hr       |
| F-05 | Hard-coded `main` across merge/PR scripts                              | Medium       | ½–1 day      |
| F-02 | Safety-critical content gates fail open on parse/timeout/hash error    | High         | 1.5–2 days   |
| F-01 | ci-pr enforcement design vs. actual branch naming                      | High (was Critical) | 2–4 days |

Out of scope (tracked separately): F-03 (`SPRINT_SESSION_ID` singleton),
F-04 (orchestration typing), F-07 (telemetry auth).

---

## F-08 — Remove stale "skeleton" headers; add stale-term lint

### Problem
`plugins/dso/scripts/merge-to-main-pr.sh:2,10,13–15,14,666` calls itself
a "skeleton implementation" / "placeholder" while containing 2,756 lines
of production PR-mode logic. The same vocabulary appears in
`plugins/dso/scripts/recipe-executor.sh:130,166` and in at least one
Python file (`figma_node_mapper.py:86`). Agents read source comments as
execution guidance.

### Steps
1. Rewrite the headers in `merge-to-main-pr.sh`, `recipe-executor.sh`,
   and any other production file flagged by the audit below. Headers
   should describe current behavior in ~5 lines.
2. Add an annotation-driven stale-term lint as a `pre-commit` hook (and
   in `.github/workflows/ci.yml`):
   - **In-scope paths:** `plugins/dso/scripts/**/*.sh`,
     `plugins/dso/hooks/**/*.sh`, `plugins/dso/scripts/**/*.py`.
   - **Excluded paths:** `tests/**`, `docs/designs/**`, `docs/adr/**`,
     `docs/archive/**`, `CHANGELOG*`, anything under `/fixtures/`.
   - **Excluded lines:** any line ending with the trailing annotation
     `# stale-term-ok` (mirrors the `# tickets-boundary-ok` pattern
     already used at `sprint/SKILL.md:132`).
   - **Vocabulary:** `skeleton implementation`, `placeholder`,
     `lands in Task`, `TODO before production`, `walking skeleton`.
     Match must be on a comment line; do not match string literals.
3. Run the lint once and rewrite or annotate every existing match. Do
   not let the lint land with a pre-populated allowlist.

### Acceptance
- Lint passes against the rewritten codebase.
- This very plan file (`docs/designs/dso-review-remediation-plan.md`)
  is excluded by the path rule, not by ad-hoc annotation.
- Deliberately re-introducing "skeleton implementation" in a comment
  fails the lint locally and in CI.

### Risk
None. Comment-only edits plus a new lint.

---

## F-06 — Honor `tickets.directory` in merge logic

### Problem
`merge-to-main-direct.sh:191–192` reads `tickets.directory` into
`_CFG_TKDIR` and uses it correctly for dirty-check exclusion
(L193–195). Five later sites fall back to the hard-coded literal:

- L208 — `git diff --name-only -- .tickets-tracker/ ...`
- L212 — `git add .tickets-tracker/`
- L442 — conflict pattern `.tickets-tracker/*/*.json`
- L782 — post-merge `git add .tickets-tracker/`
- L836 — `_TRACKER_DIR="$MAIN_REPO/.tickets-tracker"`

### Steps
1. Replace each literal with `${_CFG_TKDIR}/` (quoted as appropriate).
2. Audit the rest of the merge surface for drift:
   - `plugins/dso/scripts/merge-to-main-pr.sh`
   - `plugins/dso/scripts/merge-to-main.sh`
   - `plugins/dso/scripts/create-sprint-draft-pr.sh`
   - Any helper sourced by the above.
3. Add an annotation-driven literal guard analogous to F-08's:
   - **In-scope paths:** `plugins/dso/scripts/**`,
     `plugins/dso/hooks/**`.
   - **Excluded paths:** `tests/**`, `docs/**`, `**/fixtures/**`,
     `**/CHANGELOG*`.
   - **Excluded lines:** any line ending with `# tickets-boundary-ok`
     (existing convention).
   - **Pattern:** `\.tickets-tracker\b` outside of the canonical
     fallback assignment in `read-config.sh`-style files (which the
     allowlist will name explicitly).
4. Regression test under `tests/`: set `tickets.directory=.custom-tickets`
   in a sandbox config; create a dirty ticket file at
   `.custom-tickets/<id>.json`; exercise dirty-check, auto-commit, and
   ticket-conflict paths; assert all three honor the custom path.

### Acceptance
- All literal references outside the allowlist are removed or
  annotated.
- Regression test passes.
- Default users (no custom `tickets.directory`) see no behavior change.

### Risk
Low. Behavior change only fires when `tickets.directory` is
customized.

---

## F-05 — Default-branch resolver with safe fallback

### Problem
Verified hard-coded `main` references:

- `create-sprint-draft-pr.sh:107` — `--base main`
- `merge-to-main-pr.sh:383, 822–823` — `--base main`
- `merge-to-main-pr.sh:428–430, 445–447, 512–514` — `main..HEAD`,
  `origin/main..HEAD`
- `merge-to-main-pr.sh:688–717` — `git fetch origin main`,
  `git merge origin/main`
- `merge-to-main-direct.sh:376–380` — asserts `MAIN_BRANCH == "main"`

Note: the `llm-review` job in `ci.yml` does **not** hard-code `main` in
its diff-range computation — it uses
`github.event.pull_request.base.sha` (`ci.yml:710–711`), so the runner
is base-agnostic at the SHA level. F-05 is therefore scoped to local
merge/PR scripts only.

### Steps
1. **Create resolver** `plugins/dso/scripts/resolve-default-branch.sh`
   with this precedence (corrected from the prior draft per opus review):
   1. Config: `dso.default_branch` (if explicitly set).
   2. **`git symbolic-ref --short refs/remotes/origin/HEAD`** (local,
      no network, no auth — preferred over remote calls).
   3. `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`
      (remote, only if `gh` is authenticated).
   4. Final fallback `main` with a stderr warning.
   - Cache the resolved value in `.git/dso-default-branch` (process-
     local within a worktree); skip resolution on subsequent calls
     within the same merge run.
   - Document the config key in `CONFIGURATION-REFERENCE.md`.
2. **Replace literals** in `create-sprint-draft-pr.sh`,
   `merge-to-main-pr.sh`, `merge-to-main-direct.sh`,
   `merge-to-main.sh`, and helpers. Each script sources the resolver
   once at the top and substitutes the captured variable (e.g.,
   `_DEFAULT_BRANCH`). Replace both `main` and `origin/main`.
3. **Direct-merge assertion safety (corrected from prior draft per opus
   blocking #4):** keep the literal-`main` fast path in
   `merge-to-main-direct.sh:376–380`. Only consult the resolver when
   the host has explicitly opted in by setting `dso.default_branch` to a
   non-default value. Rationale: the direct-merge assertion is a safety
   invariant guarding against accidentally merging into a feature
   branch. Tying it to a resolver whose precedence reads from the same
   config file that a compromised host could write to weakens that
   invariant. The opt-in keeps the safety strong for the common case
   (host on `main`) and adds explicit responsibility for non-`main`
   hosts.
4. **Tests:**
   - Unit test for the resolver covering all four precedence steps
     (fake `gh`, fake symbolic-ref, fake config).
   - Integration test on a fixture repo whose default branch is
     `trunk`: with `dso.default_branch=trunk` set, run a dry-run
     `merge-to-main-pr.sh` and assert PR base is `trunk` and revision
     range is `trunk..HEAD`.
   - Negative test: with `dso.default_branch` **unset** and the
     repository's default branch resolving to `trunk`, the direct-
     merge assertion still requires `main` (the safe fast-path) — the
     resolver does not weaken the assertion silently.

### Acceptance
- `grep -nE '\b(origin/)?main\b' plugins/dso/scripts/merge-to-main*.sh
  plugins/dso/scripts/create-sprint-draft-pr.sh` returns matches only
  in comments and in the literal-string fallback in the resolver.
- Both trunk-fixture tests pass.
- Existing test suite is green.

### Risk
Medium. Mitigated by the opt-in for the direct-merge assertion and by
the cached fast-path on subsequent calls.

---

## F-02 — Gate-tier doctrine; safety-critical content gates fail closed

### Problem
Eight load-bearing fail-open sites verified. Three are Tier B
(developer-experience: a broken hook should never brick a session) and
must stay as-is. The remaining sites are content gates whose verdicts
route subsequent agent decisions; silent fail-open in those is the
real risk.

### Doctrine (the deliverable, not just the code change)
Document in `plugins/dso/docs/HOOKS-REFERENCE.md`:

- **Tier A — safety-critical.** Verdict routes execution. Must fail
  **closed** on infrastructure failure (timeout, parse error, missing
  dependency). Override requires a paired env-var bypass
  (`DSO_GATE_BYPASS_<NAME>=1` AND non-empty
  `DSO_GATE_BYPASS_<NAME>_REASON`), modeled on the
  `DSO_ALLOW_EDIT_ON_MAIN` pattern at
  `plugins/dso/hooks/lib/pre-bash-functions.sh:546–551`. Each bypass
  writes a JSONL audit record AND an event-log entry.
- **Tier B — developer-experience.** Hook wrapper, dispatcher non-2
  exits, error handler, formatting-hint hooks. Fail open is correct;
  unchanged.
- **Tier C — advisory model checks.** Heuristic verdicts that are
  routing hints, not gates. May degrade, but the degraded state must
  emit a `GATE_UNAVAILABLE` event the orchestrator can read.

### Tier assignment (verified site-by-site)

| Site | Behavior today | Tier |
|------|----------------|------|
| `plugins/dso/scripts/pre-commit-wrapper.sh` (wrapper) | exit 0 on missing/broken hook | **B** unchanged |
| `plugins/dso/hooks/lib/dispatcher.sh:55–62` | non-2 exits → allow | **B** unchanged |
| `plugins/dso/hooks/lib/hook-error-handler.sh:131` | always exit 0 after logging | **B** unchanged |
| `plugins/dso/hooks/pre-commit-test-gate.sh:47–60` | timeout (SIGTERM/SIGURG) → exit 0 | **A** flip to fail-closed |
| `plugins/dso/hooks/pre-commit-review-gate.sh:~469–474` (line corrected per opus review) | empty `CURRENT_HASH` → exit 0 | **A** flip to fail-closed |
| `plugins/dso/hooks/pre-commit-review-gate.sh:~489–491` (added per opus review) | self-heal rehash failure → exit 0 | **A** flip to fail-closed |
| `plugins/dso/skills/sprint/SKILL.md:458–461` (haiku SC gate) | parse failure → log + proceed | **C** with `GATE_UNAVAILABLE` emission |
| `plugins/dso/skills/sprint/SKILL.md:518` (sonnet SC gate) | parse failure → escalate to opus | **C** with `GATE_UNAVAILABLE` emission |
| `plugins/dso/skills/sprint/SKILL.md:576` (opus SC gate) | parse failure → treat ALL as MISSING | **C** with `GATE_UNAVAILABLE` emission |

**SC coverage gates resolved as Tier C (corrected from prior draft per
opus blocking #3):** the three SC gates implement deliberate
asymmetric fall-through (haiku → skip-to-sonnet, sonnet →
escalate-to-opus, opus → conservative-MISSING). The design note at
`sprint/SKILL.md:578` documents this as intentional graceful
degradation, not as an oversight. Promoting them to Tier A blocking
would halt Phase B entry on transient parse flakes — a high-cost
regression in a model-driven pipeline. The correct remediation is
**preserve the existing asymmetric fall-through** but add explicit
`GATE_UNAVAILABLE` emission so the verdict is machine-readable
downstream. The orchestrator may choose to act on accumulated
`GATE_UNAVAILABLE` events (e.g., three in a row → halt and surface to
operator).

### Steps

1. **Add shared helper** `plugins/dso/hooks/lib/gate-unavailable.sh`:
   - `_dso_gate_unavailable <gate_name> <reason>` — writes a JSONL
     audit record to `$HOME/.claude/logs/dso-gate-unavailable.jsonl`
     AND an event-log entry. Audit record fields:
     `timestamp`, `gate_name`, `reason`, `session_id`,
     `ticket_id`, `actor`. Returns exit code 2 for Tier A callers; for
     Tier C callers, returns 0 (the event-log entry is the signal).
   - `_dso_gate_bypass_active <gate_name>` — returns 0 only when both
     `DSO_GATE_BYPASS_<NAME>=1` and a non-empty
     `DSO_GATE_BYPASS_<NAME>_REASON` are set; emits an audit record
     when active.
   - **`session_id` / `ticket_id` propagation:** read from the
     event-log helper (which already carries these per
     `precondition-emit.sh` convention). If unavailable, log as
     `unknown` rather than crashing.
2. **Refactor Tier A sites:**
   - `pre-commit-test-gate.sh` — replace `_fail_open_on_timeout`
     (lines 47–60) with `_dso_gate_unavailable test_gate "timeout
     sig=$1"` followed by `exit 2`, unless
     `_dso_gate_bypass_active test_gate`.
   - `pre-commit-review-gate.sh` — at the two empty/missing-hash
     branches (~L469–474 and ~L489–491), call
     `_dso_gate_unavailable review_gate "hash_compute_failed"` and
     `exit 2` unless bypass active.
3. **Refactor Tier C SC gates:**
   - At each of the three SC gate fail-open paths in `sprint/SKILL.md`,
     add an `EMIT-PRECONDITIONS`-style event emission (use the existing
     event-log channel) carrying `gate_name=sc_coverage_<tier>` and
     `reason=<parse_error_summary>`.
   - **Preserve** the asymmetric fall-through (haiku→sonnet,
     sonnet→opus, opus→treat-as-MISSING). The event emission is
     additive, not a behavior change.
   - In Phase B Step 1, add a check for accumulated
     `GATE_UNAVAILABLE` events for SC gates within the current epic.
     If three or more are present without an intervening successful
     SC verdict, halt and surface to operator. This is the
     orchestrator-level brake; per-gate behavior remains the existing
     graceful degradation.
4. **Dispatcher and wrapper unchanged.** Add a header comment to each
   Tier B file naming the contract and pointing to
   `gate-unavailable.sh` for hooks that need Tier A behavior.
5. **Drift detection (added per opus significant #9):**
   - Each hook script declares its tier in the header:
     `# DSO-GATE-TIER: A|B|C`.
   - A pre-commit lint asserts every script in `plugins/dso/hooks/**`
     declares a tier.
   - A second test (run in CI, not pre-commit) asserts that every
     header-declared Tier A site contains at least one call to
     `_dso_gate_unavailable` in an error path — detected by structural
     scan, not regex (use `bash -n` parse + walk).
6. **No staging flag (corrected from prior draft per opus significant
   #6).** Drop the `hooks.tier_a_fail_closed` default-false flag idea —
   shipping a doctrine document with disabled code is the failure mode
   the brief warned against. Each Tier A site is converted in a single
   commit with the bypass env vars available from day one. Operators
   needing to keep a specific gate permissive use the per-gate bypass.

### Tests
- Unit tests for `_dso_gate_unavailable` and
  `_dso_gate_bypass_active` covering JSONL shape, event-log emission,
  session/ticket field propagation, exit codes, bypass requires both
  env vars.
- Integration test per Tier A site:
  - Test gate timeout (simulate SIGTERM during a real test
    invocation) → commit blocked, audit + event written.
  - Review gate hash failure (fixture-poison `compute-diff-hash.sh`)
    → commit blocked, audit + event written.
- Tier C SC gate test: inject malformed JSON in haiku stub → existing
  fall-through behavior preserved AND `GATE_UNAVAILABLE` event is
  emitted; Phase B continues to sonnet; third consecutive event in
  the epic halts the orchestrator.
- Bypass test per Tier A site: with both env vars set, gate is
  bypassed with audit; without the reason, bypass is rejected.

### Acceptance
- `HOOKS-REFERENCE.md` lists every gate with its tier.
- All three Tier A sites block on infrastructure failure.
- All three Tier C SC gates emit `GATE_UNAVAILABLE` events on parse
  failure while preserving the existing asymmetric fall-through.
- Tier B sites are unchanged.
- Drift-detection tests pass and would fail if a Tier A site reverted
  to silent fail-open.

### Risk
Medium. Mitigated by per-gate bypass env vars and by Tier C SC gates
preserving the existing degradation behavior (no Phase B halt
regression).

---

## F-01 — ci-pr enforcement: resolve the naming mismatch, then close real gaps

### Problem (revised based on ground truth)

The original review framed F-01 as "code can reach main without
review." Verified topology shows that is **not** the failure mode
today: every commit on `main` arrives via the Phase A long-lived
session→main PR (head=`worktree-*`, base=`main`), which triggers
`ci.yml`'s `llm-review` job. The actual situation is two adjacent
problems:

- **(P1) Documentation-vs-implementation naming drift.** The
  documented session-branch protection mechanism is configured for
  `session-*`/`session/*` patterns (`INSTALL.md:136,159`,
  `check-ruleset-preflight.sh:142–146`), but the actual session
  branches are `worktree-YYYYMMDD-HHMMSS`
  (`worktree-create.sh:124`). The Ruleset, when created per
  `INSTALL.md`, is **inert** — it matches no actual branches. The
  preflight reports OK even though no enforcement is active.
- **(P2) Per-sub-branch PR review absent.** Per-task harvest PRs
  (head=`worktree-agent-*`, base=`worktree-*`) and any non-no-diff
  story PRs (head=`story/*`, base=`worktree-*`) do not currently
  trigger `llm-review` (`ci.yml:362`: `base_ref == 'main'`).
  Aggregate review at session→main does fire, so this is a
  granularity gap, not a main-safety gap.

The plan must resolve P1 before claiming to fix anything in P2.
Otherwise widening the `ci.yml` trigger to `session-*` adds a check
context on PRs that don't exist (still `worktree-*`), and the inert
Ruleset stays inert.

### Step 1 — resolve the naming inconsistency (P1, foundational)

Decide between two paths and execute one:

**Path A — align infrastructure to actual branches.** Update
`INSTALL.md:136`, `INSTALL.md:159`, and
`check-ruleset-preflight.sh:142–146` to use `worktree-*` (and/or
`worktree-agent-*`) patterns. This is the lower-cost path because the
branch naming is already established and stable across the codebase.

**Path B — align actual branches to documented names.** Rename
`worktree-YYYYMMDD-HHMMSS` to `session-YYYYMMDD-HHMMSS` (and
`worktree-agent-*` to `session-agent-*` if per-task PRs are kept).
Requires updating `worktree-create.sh:124`, the `worktree-` regex in
several scripts (e.g., `review-defense-store.sh:664–669`,
`harvest-worktree.sh`), and the related test fixtures. Higher cost
but achieves nominal alignment with "session" terminology.

**Recommendation: Path A** because (a) `worktree-` is the established
identifier across helper scripts and tests; (b) renaming the live
worktree convention is a broad-blast-radius change that touches
session resolution, leakage detection, attribution paths, and several
fixture trees; (c) the `session-` documentation is the artifact that
hasn't kept pace with implementation reality.

Implementation:
1. Update `INSTALL.md:111–142` (UI Ruleset section) to specify
   pattern `worktree-*`. Add a parallel example for
   `worktree-agent-*` if Step 3 decides per-task review is desired.
2. Update `INSTALL.md:159` (gh CLI Ruleset spec) to use
   `refs/heads/worktree-*`.
3. Update `check-ruleset-preflight.sh:142–146` `fixed` set to
   `{"refs/heads/worktree-*", "worktree-*",
   "refs/heads/worktree/*", "worktree/*"}`. Update
   `_matches_session` helper name and contents accordingly.
4. Update `CONFIGURATION-REFERENCE.md` for `dso.review.check_name`
   (line 954) to reference `worktree-*` Rulesets, not `session-*`.
5. Update the KNOWN GAP wording at `INSTALL.md:141` to reflect the
   real state (per-sub-branch review is absent; main safety is
   intact).

### Step 2 — close the check-name mismatch (opus blocking #2)

`ci.yml:362` names the job `llm-review`.
`CONFIGURATION-REFERENCE.md:949–954` documents
`dso.review.check_name` defaulting to `Sprint Story Review`. If the
operator keeps the default and configures the Ruleset to require
`Sprint Story Review`, the actual check context produced by the job
(`llm-review`) does not satisfy the requirement — the required-check
context succeeds vacuously even after the job runs.

Decide between three paths and execute one:

**Path A — rename the job.** Change the job name from `llm-review` to
`Sprint Story Review` in `.github/workflows/ci.yml:362`. Update any
downstream references to the job name. Lowest implementation cost;
the check context published by GitHub Actions is the job name by
default.

**Path B — add an explicit status post step.** Keep the job named
`llm-review` and add a final step that posts a commit status under
the configured `dso.review.check_name` name via `gh api`.
Higher cost; gives operators a config-driven check name.

**Path C — remove the config knob.** Change
`CONFIGURATION-REFERENCE.md` to remove the `dso.review.check_name`
config key (or document it as informational only); adopt `llm-review`
as the canonical name. Update `check-ruleset-preflight.sh` default
accordingly.

**Recommendation: Path A** (rename job to `Sprint Story Review`).
The config knob exists today but its only sensible value is the one
the job already publishes. Path A makes the documented default
actually work without adding a status-post layer.

### Step 3 — decide on per-sub-branch review (P2)

Two sub-decisions:

**3a — Are per-task harvest PRs (`worktree-agent-* → worktree-*`)
required to be reviewed?**

The aggregate session→main review fires today and reviews everything
that lands on main. Adding per-task review would:
- Multiply llm-review runs by N (one per task). Deep-tier opus runs
  are expensive.
- Create verdict-divergence risk: a hunk flagged at story-grain may
  be unflagged at session-grain (the per-task reviewer has narrower
  context). If the per-task verdict is "needs changes" and the
  session-grain verdict is "approved," is the hunk approved or not?
  Today's single-grain review has no such question.

**Recommendation: do NOT widen `ci.yml:362` to include
`base_ref == 'worktree-*'` for the standard `llm-review` job.** The
main-safety case is already covered by the session→main PR review.
If per-task review is desired (e.g., for early-warning), add it as a
**separate** lightweight job (light-tier classifier only) so cost
remains bounded and verdict divergence is impossible — the per-task
job is advisory, the session→main job is authoritative.

**3b — Does session-branch protection need to be active?**

Today the `session-*` Ruleset is inert. Two desirable behaviors:
- Block direct pushes to `worktree-*` branches (already enforced by
  the `check-session-merge-only.sh` pre-commit hook locally; Ruleset
  would extend this to non-DSO clients pushing).
- Require a check on PRs into `worktree-*` (only meaningful if we
  decide per-task review is required per 3a).

**Recommendation:** keep the Ruleset, but rename pattern to
`worktree-*` (Step 1) and configure it for `non_fast_forward` only,
**not** for `required_status_checks`, unless 3a yields a positive
answer. This makes the documented "protect session branches" intent
real (blocks errant direct pushes) without coupling to per-task
review.

### Step 4 — promote Ruleset preflight to blocking when ci-pr

After Steps 1–3 land, the preflight checks something that meaningfully
maps to enforcement. Promote it to blocking:

1. Update `sprint/SKILL.md:158–169`: when `SPRINT_MODE=ci-pr`,
   preflight failure halts sprint execution.
2. Replace `2>/dev/null` suppression with structured exit-code
   handling. `check-ruleset-preflight.sh` already emits distinct
   results (`OK`, `NO_SESSION_PATTERN`, `MISSING_CHECK`, `HAS_LINEAR`).
   Surface the result token in the halt message with the operator-
   actionable remediation.
3. Provide a **scoped** bypass: per opus blocking-comment, the bypass
   must not weaken main-branch protection. Implement as two separate
   env-var pairs:
   - `DSO_GATE_BYPASS_RULESET_PREFLIGHT_SESSION=1` +
     `DSO_GATE_BYPASS_RULESET_PREFLIGHT_SESSION_REASON` — bypasses
     only the session-branch ruleset check.
   - `DSO_GATE_BYPASS_RULESET_PREFLIGHT_MAIN=1` +
     `DSO_GATE_BYPASS_RULESET_PREFLIGHT_MAIN_REASON` — bypasses only
     the main-branch ruleset check.
   - Bypassing only the session side is acceptable for degraded
     environments. Bypassing the main side requires explicit operator
     reason because main is the actual safety boundary.
4. Both bypass paths write JSONL audit records to
   `$HOME/.claude/logs/dso-preflight-bypass.jsonl` AND an event-log
   entry against the current epic.

### Step 5 — close the orchestrator-level loop

1. Phase E dispatch refuses to start when `dso.workflow=ci-pr` and
   the Phase A preflight verdict was not recorded as PASS or
   explicitly bypassed via the audit-trail env vars above.
2. The preflight verdict is written to the event log in Phase A and
   read in Phase E (the existing event-log channel survives
   compaction).
3. Update `INSTALL.md:111–142` and `CI-INTEGRATION.md` to describe
   the resolved naming, the promoted-blocking preflight, the bypass
   semantics, and the deliberate decision (per 3a) not to require
   per-task review.

### Duplication / gap analysis after F-01

**Duplication (multiple llm-review runs against the same code):**
- Within a single PR: mitigated by existing `ci.yml:47–49`
  concurrency control with `cancel-in-progress: true`.
- Across PRs at different grains:
  - Today: only session→main reviews fire. No duplication.
  - After this plan (Step 3 recommendation): unchanged. Session→main
    review remains the single authoritative grain.
  - If Step 3 is overridden later to add per-task review:
    duplication becomes real and the verdict-authority question
    must be resolved (recommend: per-task = advisory light-tier;
    session→main = authoritative).

**Gap (code reaching main without llm-review):**
- Today: closed via session→main PR + `ci.yml` `base_ref == 'main'`
  trigger.
- After Step 1 (naming alignment): unchanged. Step 1 fixes
  documentation, not enforcement granularity.
- After Step 2 (check-name resolution): **strictly tightened**. Today
  branch protection on main may not actually enforce the check
  because of the name mismatch. After Step 2, the check name
  published by the job equals the documented default required-checks
  context.
- After Step 4 (preflight blocking) with main-side bypass set: this
  is the one new "to main without review" path the plan introduces.
  Mitigated by the audit-record requirement and the separate env-var
  pair specifically for the main side. The bypass exists to allow
  fork repositories or initial setup to proceed; it is an explicit
  operator decision, not a silent fall-through.
- Direct-merge in `dso.workflow=local`: unchanged by this plan.
  Local mode has no PR and thus no llm-review by design; the local
  enforcement gates (per F-02) are the safety case for that mode.

### Acceptance
- `check-ruleset-preflight.sh` accepts `worktree-*` patterns and the
  Ruleset documented in `INSTALL.md` actually matches the branches
  the sprint workflow creates.
- The `llm-review` job's check context matches the documented
  `dso.review.check_name` default — verified by a CI smoke test that
  opens a session→main PR and asserts the configured context name
  appears.
- Phase A preflight in ci-pr mode halts sprint execution on
  `MISSING_CHECK`, `NO_SESSION_PATTERN`, or `HAS_LINEAR`; halts
  message names the result token and a remediation command.
- Two-env-var bypass works for each side independently and writes
  audit records.
- Phase E refuses to dispatch when ci-pr and the preflight verdict
  is missing or non-PASS without a recorded bypass.

### Risk
High blast radius. Mitigated by:
- Sequencing Step 1 (documentation) and Step 2 (job name) ahead of
  Step 4 (blocking). Steps 1–2 are independently safe; the blocking
  promotion only lands once the preflight checks something real.
- The bypass envelope keeps degraded environments unblocked.
- The non-recommendation against widening the trigger (Step 3a)
  avoids the largest blast-radius change in the original plan.

---

## Sequencing summary (revised)

1. **F-08** (~1 hr) — header rewrites in `merge-to-main-pr.sh`,
   `recipe-executor.sh`, and any other audit-discovered file; add
   annotation-driven stale-term lint with proper exclusions.
2. **F-06** (1–2 hr) — honor `tickets.directory` everywhere;
   annotation-driven literal guard; regression test.
3. **F-05** (½–1 day) — `resolve-default-branch.sh` with
   symbolic-ref-first precedence; literal-`main` fast-path retained
   for direct-merge assertion; replace literals in merge scripts.
4. **F-02** (1.5–2 days) — gate-tier doctrine; Tier A flip for two
   gate sites (test-gate, review-gate hash); Tier C
   `GATE_UNAVAILABLE` emission preserving SC gate fall-through;
   drift-detection lint; no staging flag.
5. **F-01** (2–4 days) — Step 1 naming alignment; Step 2 job rename;
   Step 3 documented decision (no per-task widening); Step 4
   blocking preflight with scoped bypasses; Step 5 orchestrator
   gate.

Ordering constraints:
- **F-05 must land before F-01** — Step 4's preflight messages will
  reference the default branch when describing main-side rules.
- **F-02 must land before F-01 Step 4** — F-01 Step 4's bypass
  env-var pattern reuses the `_dso_gate_unavailable` helper and
  paired-bypass convention. Landing F-02 first means F-01 inherits
  a proven helper instead of inventing a parallel mechanism.
- **F-06 and F-08 may land in parallel** — no shared code path.

## Cross-cutting changes versus the prior plan

| Section | Prior plan | Revised plan | Reason |
|---------|------------|--------------|--------|
| F-01 severity | Critical | High | Verified: no current "to main without review" path |
| F-01 Step 1 trigger widening to `session-*` | Yes | **No** | Branches are `worktree-*`; widening would not match reality |
| F-01 check-name resolution | Vague | Path A — rename job | Opus blocking #2 |
| F-01 preflight bypass | Single env-var pair | Two scoped pairs (session, main) | Opus question on bypass-weakens-main |
| F-02 review-gate site line | 84–88 | 469–474 + 489–491 | Opus blocking #1 (corrected) |
| F-02 SC gates | Promote to Tier A | Tier C with `GATE_UNAVAILABLE` | Opus blocking #3 + design note `sprint/SKILL.md:578` |
| F-02 staging flag | Default-false | Removed | Opus significant #6 |
| F-02 audit fields | timestamp/gate/reason | + session_id/ticket_id | Opus minor #12 |
| F-05 resolver order | config → gh → symbolic-ref → main | config → symbolic-ref → gh → main | Opus significant #7 |
| F-05 direct-merge assertion | Resolver-driven | Literal-`main` fast path; resolver only on opt-in | Opus blocking #4 |
| F-06 literal guard | Hard regex | Annotation-driven (`# tickets-boundary-ok`) | Opus significant #5 |
| F-08 lint exclusions | tests/ only | + docs/designs/, docs/adr/, CHANGELOG | Opus minor #10 |
| Drift detection | Not addressed | Tier A header + call-site structural scan | Opus significant #9 |
| Rollback procedure | Not addressed | Each Step 1–5 lands as a separate PR | Opus minor #11 |

## Tracking

Create one ticket per finding under the existing review-evaluation
epic; link via `--parent`. Use the standard story type for F-01,
F-02, and F-05 (multi-task); task type for F-06 and F-08 (single
deliverable). Verify via
`.claude/scripts/dso ticket list --status=in_progress` on session
resume.
