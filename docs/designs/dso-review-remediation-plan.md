# DSO Review Remediation Plan — F-02, F-05, F-06, F-08

Plan to implement four findings from the static review of the DSO agentic
workflow plugin. **F-01 (ci-pr enforcement) has been dropped from this
plan** — the live two-grain review topology (`review-sub-pr.yml` for
sub-branch PRs + `ci.yml`'s `llm-review` for session→main) plus the in-
flight sub-pr-cutover migration framework
(`docs/migration-exemptions/sub-pr-cutover.jsonl`, `migration-grace`
label, `promote-ruleset-required.sh`) make F-01 too complex to specify
correctly without a workflow-architect-in-the-loop. Repeated review
passes surfaced repeated misreadings of the live behavior. F-01 work
should be planned by a human with full context of the cutover migration.

The four remaining findings are mechanically bounded, do not touch the
sprint orchestrator's complex routing, and are independently testable.

## Scope

| ID   | Finding                                                                | Severity     | Est. effort  |
|------|------------------------------------------------------------------------|--------------|--------------|
| F-08 | Stale "skeleton/future task" header in `merge-to-main-pr.sh` and peers | Low-Medium   | ~1 hr        |
| F-06 | `tickets.directory` honored only partially in merge logic              | Medium       | 1–2 hr       |
| F-05 | Hard-coded `main` across merge/PR scripts                              | Medium       | ½–1 day      |
| F-02 | Safety-critical content gates fail open on parse/timeout/hash error    | High         | 1.5–2 days   |

Out of scope (tracked separately): F-01 (ci-pr enforcement), F-03
(`SPRINT_SESSION_ID` singleton), F-04 (orchestration typing), F-07
(telemetry auth).

---

## F-08 — Remove stale "skeleton" headers; add stale-term lint

### Problem
`plugins/dso/scripts/merge-to-main-pr.sh:2,10,13–15,666` calls itself a
"skeleton implementation" / "placeholder" while containing 2,756 lines of
production PR-mode logic. The same vocabulary appears in
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
   with this precedence:
   1. Config: `dso.default_branch` (if explicitly set).
   2. **`git symbolic-ref --short refs/remotes/origin/HEAD`** (local,
      no network, no auth — preferred over remote calls).
   3. `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`
      (remote, only if `gh` is authenticated).
   4. Final fallback `main` with a stderr warning.
   - **Cache invalidation rule:** cache the resolved value in
     `.git/dso-default-branch`, but invalidate at the start of each
     `merge-to-main.sh` invocation (write a fresh value during the
     dispatcher's setup phase). Do NOT cache across separate
     merge-to-main runs — the default branch could be renamed
     upstream between sprint phases.
   - Document the config key in `CONFIGURATION-REFERENCE.md`.
2. **Replace literals** in `create-sprint-draft-pr.sh`,
   `merge-to-main-pr.sh`, `merge-to-main-direct.sh`,
   `merge-to-main.sh`, and helpers. Each script sources the resolver
   once at the top and substitutes the captured variable (e.g.,
   `_DEFAULT_BRANCH`). Replace both `main` and `origin/main`.
3. **Direct-merge assertion safety:** keep the literal-`main`
   fast-path in `merge-to-main-direct.sh:376–380`. Only consult the
   resolver when the host has explicitly opted in by setting
   `dso.default_branch` to a non-default value. Rationale: the
   direct-merge assertion is a safety invariant guarding against
   accidentally merging into a feature branch. Tying it to a resolver
   whose precedence reads from the same config file that a
   compromised host could write to weakens that invariant. The
   opt-in keeps the safety strong for the common case (host on `main`)
   and adds explicit responsibility for non-`main` hosts.
4. **Failure-mode message:** when `dso.default_branch` is unset AND
   the resolver returns something other than `main`, the direct-merge
   path must emit a clear actionable error:
   `Direct merge refused: detected default branch '<X>' but
   dso.default_branch is not set. Set dso.default_branch=<X> in
   .claude/dso-config.conf to authorize merges into this branch, or
   use ci-pr mode.` This prevents a silent halt on non-`main` hosts
   without weakening the safety invariant.
5. **Tests:**
   - Unit test for the resolver covering all four precedence steps
     (fake `gh`, fake symbolic-ref, fake config).
   - Cache-invalidation test: pre-populate `.git/dso-default-branch`
     with a stale value; assert the next `merge-to-main.sh` invocation
     overwrites it.
   - Integration test on a fixture repo whose default branch is
     `trunk`: with `dso.default_branch=trunk` set, run a dry-run
     `merge-to-main-pr.sh` and assert PR base is `trunk` and revision
     range is `trunk..HEAD`.
   - Negative test: with `dso.default_branch` **unset** and the
     repository's default branch resolving to `trunk`, the direct-
     merge assertion still refuses with the message in Step 4 — the
     resolver does not weaken the assertion silently.

### Acceptance
- `grep -nE '\b(origin/)?main\b' plugins/dso/scripts/merge-to-main*.sh
  plugins/dso/scripts/create-sprint-draft-pr.sh` returns matches only
  in comments and in the literal-string fallback in the resolver.
- Both trunk-fixture tests pass.
- Cache-invalidation test passes.
- Existing test suite is green.

### Risk
Medium. Mitigated by:
- The opt-in for the direct-merge assertion (no silent regression
  for `main`-default hosts).
- The cache-invalidation rule (no stale-default-branch class of bugs).
- The explicit failure message (operators on non-`main` hosts get a
  clear action, not a silent halt).

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
| `plugins/dso/hooks/pre-commit-review-gate.sh:~469–474` | empty `CURRENT_HASH` → exit 0 | **A** flip to fail-closed |
| `plugins/dso/hooks/pre-commit-review-gate.sh:~489–491` | self-heal rehash failure → exit 0 | **A** flip to fail-closed |
| `plugins/dso/skills/sprint/SKILL.md:458–461` (haiku SC gate) | parse failure → log + proceed | **C** with `GATE_UNAVAILABLE` emission |
| `plugins/dso/skills/sprint/SKILL.md:518` (sonnet SC gate) | parse failure → escalate to opus | **C** with `GATE_UNAVAILABLE` emission |
| `plugins/dso/skills/sprint/SKILL.md:576` (opus SC gate) | parse failure → treat ALL as MISSING | **C** with `GATE_UNAVAILABLE` emission |

**SC coverage gates are Tier C, not Tier A.** The three SC gates
implement deliberate asymmetric fall-through (haiku → skip-to-sonnet,
sonnet → escalate-to-opus, opus → conservative-MISSING). The design
note at `sprint/SKILL.md:578` documents this as intentional graceful
degradation. Promoting them to Tier A blocking would halt Phase B
entry on transient parse flakes — a high-cost regression in a model-
driven pipeline. The correct remediation is **preserve the existing
asymmetric fall-through** but add explicit `GATE_UNAVAILABLE`
emission so the verdict is machine-readable downstream.

### Steps

1. **Add shared helper** `plugins/dso/hooks/lib/gate-unavailable.sh`:
   - `_dso_gate_unavailable <gate_name> <reason>` — writes a JSONL
     audit record to `$HOME/.claude/logs/dso-gate-unavailable.jsonl`
     AND an event-log entry. Audit record fields:
     `timestamp`, `gate_name`, `reason`, `session_id`,
     `ticket_id`, `actor`. Returns exit code 2 for Tier A callers;
     for Tier C callers, returns 0 (the event-log entry is the
     signal).
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
4. **Orchestrator-level three-strikes brake (scoped per opus review):**
   - In Phase B Step 1, before reading SC verdicts, scan the event
     log for `GATE_UNAVAILABLE` events scoped to the current epic.
   - **Counter scope:** per-gate-tier, NOT aggregated across the
     three tiers. So three consecutive haiku failures could trigger
     a halt; three failures spread across haiku/sonnet/opus would not.
   - **Reset on success:** the counter for a tier resets when ANY
     successful verdict from that tier is recorded in the event log
     for the current epic. The brake does not accumulate stale
     counts across re-runs of the same gate within an epic.
   - **Halt condition:** three consecutive failures of the same tier
     within the current epic, with no intervening success. On halt,
     surface a precise message naming the tier and the three reason
     strings; suggest re-running with the existing bypass envelope
     once the underlying parse issue is fixed.
   - **Rationale for per-tier scoping:** a partial Anthropic API
     outage (a real failure mode worth designing for) could degrade
     all three tiers simultaneously. An aggregated three-strikes
     counter would halt on a single API outage. Per-tier scoping
     means the halt only fires when a specific tier is persistently
     broken, not when there's a transient cross-tier blip.
5. **Dispatcher and wrapper unchanged.** Add a header comment to each
   Tier B file naming the contract and pointing to
   `gate-unavailable.sh` for hooks that need Tier A behavior.
6. **Drift detection:**
   - Each hook script declares its tier in the header:
     `# DSO-GATE-TIER: A|B|C`.
   - A pre-commit lint asserts every script in `plugins/dso/hooks/**`
     declares a tier.
   - A second test (run in CI, not pre-commit) asserts that every
     header-declared Tier A site contains at least one call to
     `_dso_gate_unavailable` in an error path — detected by structural
     scan, not regex (use `bash -n` parse + walk).
7. **No staging flag.** Drop the `hooks.tier_a_fail_closed`
   default-false flag idea — shipping a doctrine document with
   disabled code is the failure mode the brief warned against. Each
   Tier A site is converted in a single commit with the bypass env
   vars available from day one. Operators needing to keep a specific
   gate permissive use the per-gate bypass.

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
  emitted; Phase B continues to sonnet; third consecutive haiku event
  in the same epic halts the orchestrator with a precise message;
  a successful haiku verdict between failures resets the counter.
- **Cross-tier outage test:** inject malformed JSON in haiku stub,
  then in sonnet stub, then in opus stub (all within the same epic,
  no successful intervening verdicts) → orchestrator does NOT halt
  (failures are not aggregated across tiers); but the operator-
  visible event log surfaces three `GATE_UNAVAILABLE` entries.
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
- Three-strikes brake is per-gate-tier, resets on success, does not
  fire on cross-tier API outages.

### Risk
Medium. Mitigated by:
- Per-gate bypass env vars for Tier A sites.
- Tier C SC gates preserving existing degradation behavior (no Phase B
  halt regression on transient flakes).
- Per-tier three-strikes scoping (no API-outage halt regression).

---

## Sequencing summary

1. **F-08** (~1 hr) — header rewrites in `merge-to-main-pr.sh`,
   `recipe-executor.sh`, and any other audit-discovered file; add
   annotation-driven stale-term lint with proper exclusions.
2. **F-06** (1–2 hr) — honor `tickets.directory` everywhere;
   annotation-driven literal guard; regression test.
3. **F-05** (½–1 day) — `resolve-default-branch.sh` with
   symbolic-ref-first precedence and per-merge-run cache invalidation;
   literal-`main` fast-path retained for direct-merge assertion;
   explicit failure message on non-`main` hosts without
   `dso.default_branch`.
4. **F-02** (1.5–2 days) — gate-tier doctrine; Tier A flip for three
   gate sites (test-gate, review-gate hash, review-gate rehash);
   Tier C `GATE_UNAVAILABLE` emission preserving SC gate fall-through;
   per-gate-tier three-strikes orchestrator brake; drift-detection
   lint; no staging flag.

Ordering constraints:
- **F-05 may land before F-02** — they touch independent surfaces.
- **F-06 and F-08 may land in parallel** — no shared code path.
- All four findings are independent of any future F-01 work; each
  can land before the F-01 plan is even drafted.

## Why F-01 was dropped

The live ci-pr enforcement topology is two-grain (`review-sub-pr.yml`
on sub-branch PRs + `ci.yml`'s `llm-review` on session→main PRs) with
an in-flight migration framework
(`docs/migration-exemptions/sub-pr-cutover.jsonl`, `migration-grace`
label, `promote-ruleset-required.sh`,
`validate-required-checks.sh`). Reasoning correctly about this surface
requires understanding:

- Which workflow publishes which check name to what branch-protection
  ruleset.
- The current state of the sub-pr-cutover migration (staged →
  required → enforced).
- The interaction between `check-session-merge-only.sh` (local
  hook), the `worktree-*` branch convention, and the documented
  `session-*` ruleset pattern.
- The `bug-batch/**` and `session/**` legacy patterns in
  `review-sub-pr.yml:5–7` and whether they're live or vestigial.
- The verdict-authority rule between per-sub-branch review (advisory
  or authoritative?) and session→main review.

Three review passes have produced three different mental models of
this surface, each later shown to be incomplete. The risk of
specifying a fix against a wrong mental model — committing
documentation rewrites, ruleset reconfigurations, or workflow
trigger changes that contradict the live migration's next phase —
outweighs the value of including F-01 in this autonomous plan. F-01
work should be planned by a human with concurrent context of the
sub-pr-cutover migration's current phase.

## Cross-cutting changes versus the prior plan

| Section | Prior plan | Revised plan | Reason |
|---------|------------|--------------|--------|
| F-01 | Critical-severity step with naming alignment + check-name rename + preflight blocking | **Dropped** | Live two-grain topology + sub-pr-cutover migration framework make autonomous F-01 specification unsafe |
| F-02 review-gate site line | 84–88 | 469–474 + 489–491 | Opus blocking #1 (verified) |
| F-02 SC gates | Promote to Tier A | Tier C with `GATE_UNAVAILABLE` | Preserves intentional asymmetric fall-through at `sprint/SKILL.md:578` |
| F-02 three-strikes counter | Unspecified scope | Per-gate-tier, reset on success | Second opus review — prevents API-outage halt regression |
| F-02 staging flag | Default-false | Removed | Avoids "doctrine ships but code disabled" failure mode |
| F-02 audit fields | timestamp/gate/reason | + session_id/ticket_id | Audit must be retrievable per epic |
| F-05 resolver order | config → gh → symbolic-ref → main | config → symbolic-ref → gh → main | Local-first; avoids `gh` auth exposure on hot path |
| F-05 cache | Process-local only | `.git/dso-default-branch`, invalidated per merge-to-main run | Prevents stale-default-branch across separate runs |
| F-05 direct-merge assertion | Resolver-driven | Literal-`main` fast path; resolver only on opt-in; explicit failure message | Safety invariant preservation + actionable non-`main` host path |
| F-06 literal guard | Hard regex | Annotation-driven (`# tickets-boundary-ok`) | Avoids 165+ false positives in fixtures/docs |
| F-08 lint exclusions | tests/ only | + docs/designs/, docs/adr/, CHANGELOG | Prevents false-positives on plan/design files |
| Drift detection | Not addressed | Tier A header + call-site structural scan | Detects regression of Tier A → silent fail-open |

## Tracking

Create one ticket per finding under the existing review-evaluation
epic; link via `--parent`. Use the standard story type for F-02 and
F-05 (multi-task); task type for F-06 and F-08 (single deliverable).
Verify via `.claude/scripts/dso ticket list --status=in_progress` on
session resume.
