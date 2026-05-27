# DSO Review Remediation Plan — F-01, F-02, F-05, F-06, F-08

Plan to implement five findings from the static review of the DSO agentic
workflow plugin. Findings are ordered by ascending blast-radius / effort so
that the trivial wins land first and the load-bearing change (F-01) lands on
a clean baseline.

## Scope

| ID   | Finding                                                              | Severity     | Est. effort |
|------|----------------------------------------------------------------------|--------------|-------------|
| F-08 | Stale "skeleton/future task" header in `merge-to-main-pr.sh`         | Low-Medium   | ~30 min     |
| F-06 | `tickets.directory` honored only partially in merge logic            | Medium       | 1–2 hr      |
| F-05 | Hard-coded `main` across merge/PR scripts                            | Medium       | ½–1 day     |
| F-02 | Safety-critical content gates fail open on parse/timeout/hash error  | High         | 1.5–2 days  |
| F-01 | `ci-pr` mode skips local gates while session-branch CI check missing | **Critical** | 1–3 days    |

Out of scope for this plan (tracked separately): F-03 (`SPRINT_SESSION_ID`
singleton), F-04 (orchestration typing), F-07 (telemetry auth).

---

## F-08 — Remove stale "skeleton" header in `merge-to-main-pr.sh`

### Problem
`plugins/dso/scripts/merge-to-main-pr.sh:2,13–15` calls itself a
"skeleton implementation" that "lands in Task 3." The file is 2,756 lines of
production PR-mode logic (sync, push, `gh pr create`, mergeability checks,
auto-merge sequencing). Agents read source comments as execution guidance;
calling a live merge path a skeleton is an integrity hazard.

### Steps
1. Rewrite the file header to describe what the script does today (PR merge
   mode: sync, push, create PR, finalize, auto-merge). Keep the header to
   ~5 lines.
2. Add a lightweight CI check in `.github/workflows/ci.yml` (or
   `.pre-commit-config.yaml`) that greps production scripts for the
   stale-term vocabulary and fails on match.
   - Files in scope: `plugins/dso/scripts/**/*.sh`,
     `plugins/dso/hooks/**/*.sh`.
   - Terms: `skeleton`, `placeholder`, `lands in Task`, `TODO before
     production`.
   - Exclusion: matches inside a fenced code block or a regression-test
     fixture path under `tests/`.
3. Audit the rest of `plugins/dso/scripts/merge-to-main-*.sh` and
   `create-sprint-draft-pr.sh` for the same vocabulary; rewrite as needed.

### Acceptance
- `grep -rE 'skeleton|placeholder|lands in Task' plugins/dso/scripts/` returns
  no matches outside test fixtures.
- CI check fires on a deliberately-staled comment in a throwaway branch.

### Risk
None. Comment-only edit + new lint. No behavior change.

---

## F-06 — Honor `tickets.directory` in merge logic

### Problem
`plugins/dso/scripts/merge-to-main-direct.sh` reads `tickets.directory` into
`_CFG_TKDIR` (line 191–192) and uses it for the dirty-check exclusion
(line 193–195). Several later sites fall back to the hard-coded
`.tickets-tracker/` literal:

- L208 — `git diff --name-only -- .tickets-tracker/ ...`
- L212 — `git add .tickets-tracker/`
- L442 — conflict pattern: `.tickets-tracker/*/*.json` and
  `.tickets-tracker/*.json`
- L782 — post-merge `git add .tickets-tracker/`
- L836 — `_TRACKER_DIR="$MAIN_REPO/.tickets-tracker"`

A host project that customizes `tickets.directory` will see the merge
workflow treat ticket files as normal dirty files, fail to auto-commit them,
and fail to auto-resolve ticket-data conflicts.

### Steps
1. Replace each `.tickets-tracker/` literal in `merge-to-main-direct.sh`
   with `${_CFG_TKDIR}/` (or the equivalent quoted form).
2. Search the rest of the merge surface for the same drift:
   - `plugins/dso/scripts/merge-to-main-pr.sh`
   - `plugins/dso/scripts/merge-to-main.sh`
   - `plugins/dso/scripts/create-sprint-draft-pr.sh`
   - Any helper sourced by the above.
3. Add a regression test under `tests/` that:
   - Sets `tickets.directory=.custom-tickets` in a sandbox config.
   - Creates a dirty ticket file at `.custom-tickets/<id>.json`.
   - Exercises dirty-check, auto-commit, and ticket-conflict paths.
   - Asserts the file is auto-committed and that conflict-recognition fires
     for the custom path.
4. Add a `pre-commit` (or test-gate) grep guard: in non-test code under
   `plugins/dso/scripts/` and `plugins/dso/hooks/`, literal
   `.tickets-tracker` is prohibited; the resolver helper is the only
   permitted source. Allowlist `tests/`, `docs/`, and fixture paths.

### Acceptance
- New regression test passes.
- Repository search confirms no remaining `.tickets-tracker` literals outside
  the allowlist.
- `make test` (or the project's equivalent) is green.

### Risk
Low. Behavior change only fires for users who set a non-default
`tickets.directory`; default users are unaffected because `_CFG_TKDIR`
already defaults to `.tickets-tracker`.

---

## F-05 — Default-branch resolver, remove hard-coded `main`

### Problem
Merge and PR scripts assume the integration branch is named `main`. Verified
sites:

- `plugins/dso/scripts/create-sprint-draft-pr.sh:107` — `--base main`
- `plugins/dso/scripts/merge-to-main-pr.sh:383, 822–823` — `--base main`
- `plugins/dso/scripts/merge-to-main-pr.sh:428–430, 445–447, 512–514` —
  `main..HEAD`, `origin/main..HEAD`
- `plugins/dso/scripts/merge-to-main-pr.sh:688–717` — `git fetch origin main`,
  `git merge origin/main`
- `plugins/dso/scripts/merge-to-main-direct.sh:376–380` — asserts
  `MAIN_BRANCH == "main"`

Hard-coding `main` causes false diffs, wrong PR bases, failed merges, or
accidental branch targeting for host projects on `master`, `develop`,
`trunk`, or a release branch.

### Steps
1. **Create resolver** `plugins/dso/scripts/resolve-default-branch.sh`:
   - Precedence:
     1. Config: `dso.default_branch` (read via the standard config helper).
     2. `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`
        when `gh` is authenticated and a remote exists.
     3. `git symbolic-ref --short refs/remotes/origin/HEAD` (strips
        `origin/`).
     4. Fallback `main` with a stderr warning.
   - Output a single branch name on stdout; nonzero exit only when no
     fallback applies (should be rare; the literal `main` fallback always
     succeeds).
   - Caches result in a process-local variable to avoid repeated `gh`
     calls.
2. **Document the config key** in
   `plugins/dso/docs/CONFIGURATION-REFERENCE.md` under a new
   `dso.default_branch` entry. Cross-reference from `dso.workflow`.
3. **Replace literals** in:
   - `create-sprint-draft-pr.sh`
   - `merge-to-main-pr.sh`
   - `merge-to-main-direct.sh`
   - `merge-to-main.sh`
   - Any helper that constructs revision ranges.

   Each script sources the resolver once at the top and substitutes the
   captured variable (e.g. `_DEFAULT_BRANCH`). Replace both `main` and
   `origin/main` (where used as the remote-tracking ref).
4. **Direct-merge assertion update** (`merge-to-main-direct.sh:376–380`):
   change the `MAIN_BRANCH == "main"` check to `MAIN_BRANCH == "$_DEFAULT_BRANCH"`.
   Preserve the safety intent (only allow direct merge into the
   integration branch, never into a feature branch).
5. **Test coverage**:
   - Unit test for the resolver covering all four precedence steps (use a
     fake `gh` and a fake git env).
   - Regression test on a fixture repo whose default branch is `trunk`:
     run a dry-run merge-to-main-pr flow and assert the PR base is `trunk`
     and the revision range is `trunk..HEAD`.

### Acceptance
- `grep -nE '\b(origin/)?main\b' plugins/dso/scripts/merge-to-main*.sh
  plugins/dso/scripts/create-sprint-draft-pr.sh` returns matches only in
  comments and the literal-string fallback in `resolve-default-branch.sh`.
- Trunk-fixture test passes.
- Existing test suite is green.

### Risk
Medium. The merge scripts are load-bearing for release. Mitigations:
- Land in a feature branch and dogfood through one full
  `merge-to-main.sh` cycle on this repo (where the integration branch
  *is* `main`) before merging.
- Keep the `main` fallback so a misconfigured host doesn't deadlock.

---

## F-02 — Classify gates; safety-critical ones fail closed

### Problem
Eight load-bearing fail-open sites were verified. The reviewer's framing
correctly notes that several are *deliberate developer-experience choices*
(a broken hook should never brick an editor session). The genuine
correctness risk is in the **content gates** that carry the workflow's
safety claims — review hash failure, sprint scope-certainty (SC) coverage
gate, test-gate timeout when the gate is supposed to actually evaluate, and
Ruleset preflight (overlaps with F-01).

The hazard is not "fail-open exists" but "fail-open silently in places
where the orchestrator's later phases treat the gate as having passed."
Local logs are invisible to downstream agent decisions.

### Doctrine (the deliverable, not just the code change)
Classify every gate into one of three tiers and document the doctrine in
`plugins/dso/docs/HOOKS-REFERENCE.md`:

- **Tier A — safety-critical.** Review, tests, provenance, branch/merge
  invariants, scope-coverage gates whose verdicts route execution. Must
  fail **closed** on infrastructure failure (timeout, parse error, missing
  dependency). Override requires an explicit, audited bypass env var
  modeled on `DSO_ALLOW_EDIT_ON_MAIN` (paired var + non-empty reason
  string), and the bypass writes a JSONL audit record.
- **Tier B — developer-experience.** Hook wrapper, dispatcher non-2
  exits, error handler, post-tool formatting hints. Fail open is
  correct; keep as-is.
- **Tier C — advisory model checks.** Heuristic coverage/clarity
  classifiers whose verdict is not load-bearing. May degrade, but the
  degraded state must be **explicit and machine-readable** (emit a
  `GATE_UNAVAILABLE` event the orchestrator can read), never silent.

### Steps

#### Phase 1 — classify
1. **Inventory** every fail-open site under `plugins/dso/hooks/` and
   `plugins/dso/scripts/`. Use the eight verified sites as the seed set:
   - `plugins/dso/scripts/pre-commit-wrapper.sh` (wrapper) — **B**
   - `plugins/dso/hooks/lib/dispatcher.sh:55–62` (non-2 exits) — **B**
   - `plugins/dso/hooks/lib/hook-error-handler.sh:131` (always exit 0) —
     **B**
   - `plugins/dso/hooks/pre-commit-test-gate.sh:47–60` (timeout
     `_fail_open_on_timeout`) — **A** (test verdict is load-bearing)
   - `plugins/dso/hooks/pre-commit-review-gate.sh:84–88` (diff-hash
     compute failure) — **A** (review verdict is load-bearing)
   - `plugins/dso/skills/sprint/SKILL.md:458–461` (haiku SC gate) —
     **A or C** depending on whether the verdict gates Phase B entry;
     classify per Phase B's existing routing logic
   - `plugins/dso/skills/sprint/SKILL.md:518` (sonnet SC gate) — same
   - `plugins/dso/skills/sprint/SKILL.md:576` (opus SC gate) — same
2. **Document the classification** in `HOOKS-REFERENCE.md` with the
   tier letter inline next to each gate description. This is the
   contract; future hooks must declare a tier in their header comment.

#### Phase 2 — implement the Tier A pattern
3. **Add a shared helper** `plugins/dso/hooks/lib/gate-unavailable.sh`
   exporting:
   - `_dso_gate_unavailable <gate_name> <reason>` — writes a structured
     JSONL audit record to `$HOME/.claude/logs/dso-gate-unavailable.jsonl`
     and to the event log (via the existing event-log helper), then
     returns exit code 2 (the dispatcher's "block" code).
   - `_dso_gate_bypass_active <gate_name>` — returns 0 only when both
     `DSO_GATE_BYPASS_${gate_name^^}=1` and a non-empty
     `DSO_GATE_BYPASS_${gate_name^^}_REASON` are set; emits an audit
     record when active.
4. **Refactor Tier A sites** to use the helper:
   - `pre-commit-test-gate.sh` — on timeout (existing
     `_fail_open_on_timeout` trap on TERM/URG), call
     `_dso_gate_unavailable test_gate "timeout sig=$1"` and exit 2
     unless `_dso_gate_bypass_active test_gate`. Preserve the
     existing comment rationale, but invert the default.
   - `pre-commit-review-gate.sh` — on diff-hash compute failure, same
     pattern: `_dso_gate_unavailable review_gate "hash_compute_failed"`.
5. **Refactor SC coverage gates** in `sprint/SKILL.md`:
   - Lines 458–461, 518, 576: replace "fail-open — log a warning and
     proceed" with "emit `GATE_UNAVAILABLE` event; orchestrator halts
     Phase B entry pending operator decision."
   - The orchestrator gets a new check at the top of Phase B Step 1
     that reads the event log for any `GATE_UNAVAILABLE` for SC gates
     and halts with a precise message if found. The halt produces a
     ticket comment with the gate name and the underlying parse error,
     mirroring the existing precondition fallthrough pattern.

#### Phase 3 — extend the doctrine to the dispatcher
6. **Keep dispatcher behavior unchanged** (`dispatcher.sh:55–62`): non-2
   exits remain fail-open by design — that's the Tier B contract. The
   change is documentation, not code: add a comment block at the top of
   `dispatcher.sh` that names the contract and points to the Tier A
   helper for hooks that need fail-closed behavior.
7. **Pre-commit lint**: add a grep guard that flags new hook scripts
   missing a tier declaration in their header. Allowlist the eight
   pre-existing sites until they're refactored.

#### Phase 4 — tests
8. **Unit tests** for `_dso_gate_unavailable` and
   `_dso_gate_bypass_active`: verifies JSONL shape, audit record fields
   (timestamp, gate name, reason, bypass actor), exit codes, and that
   the bypass requires both env vars present.
9. **Integration tests** (one per Tier A site):
   - Test gate timeout: simulate SIGTERM during a real test invocation;
     assert commit is blocked, audit record written, ticket comment
     surfaced.
   - Review gate hash failure: poison `compute-diff-hash.sh` (test
     fixture); assert commit blocked with `review_gate` audit entry.
   - SC gate parse failure: inject malformed JSON in the haiku stub;
     assert Phase B halts and Phase E is never dispatched.
10. **Bypass test** for each Tier A site: with `DSO_GATE_BYPASS_<name>=1`
    and a non-empty reason, the gate is bypassed and the bypass is
    audited. Without the reason, the bypass is rejected.

### Acceptance
- `HOOKS-REFERENCE.md` lists every gate with its tier letter; new hooks
  fail the pre-commit lint if they omit the declaration.
- All three Tier A sites (test gate, review gate, SC coverage) block
  rather than silently passing on infrastructure failure.
- Each Tier A site has working audit records and a documented bypass
  env-var pair.
- Tier B sites (wrapper, dispatcher non-2, error handler) are
  **unchanged**; the wrapper still fails open on a broken hook script
  (correct behavior).
- New unit + integration tests pass; existing test suite is green.

### Risk
Medium-high. Inverting "silently allow" to "block" can surface
infrastructure-flake commits as failures that previously slipped
through. Mitigations:
- Stage rollout: Tier A flag (`hooks.tier_a_fail_closed`, default
  false during the first release cycle) so the new behavior can be
  reverted independently.
- Each bypass env var is per-gate; operators can keep specific gates
  permissive while tightening the rest.
- Audit records make the silent-failure case discoverable retroactively
  even before fail-closed flips on.

### Doctrine note
This is *not* a recommendation to remove fail-open behavior wholesale.
The hook wrapper's fail-open on broken hook scripts is correct design
— a syntax error in one hook must not brick every editor session. The
remediation narrows the change to gates whose verdicts route subsequent
agent decisions, which is the actual safety case.

---

## F-01 — Close the `ci-pr` enforcement gap (Critical)

### Problem
In `dso.workflow=ci-pr` mode:

1. Local gates skip body: `plugins/dso/hooks/lib/enforcement-gate.sh:49–51`
   logs `HOOK_GATE: skipped reason=dso.workflow=ci-pr` and returns 0;
   `pre-commit-{review,test}-gate.sh` honor this and exit 0.
2. The Ruleset preflight in `plugins/dso/skills/sprint/SKILL.md:164–169`
   is *advisory*: on failure it logs WARNING and continues.
3. The `Sprint Story Review` check that branch protection expects on
   session branches is never produced. `.github/workflows/ci.yml:362–364`
   gates the `llm-review` job to
   `github.event_name == 'pull_request' && github.base_ref == 'main'`. PRs
   into `session-*` do not match.
4. `INSTALL.md:141` already calls this out as a "KNOWN GAP".

Net effect: a multi-agent sprint runs assuming "CI is enforcing review"
when the expected check is not emitted, and the local gate that would
otherwise catch it is skipped by design.

### Steps

#### Phase 1 — emit the check on session-base PRs
1. **Widen the `llm-review` trigger** in `.github/workflows/ci.yml`:
   - Change the job-level `if:` from
     `github.event_name == 'pull_request' && github.base_ref == 'main'`
     to a base-ref pattern that includes session branches.
   - Implementation: GitHub Actions `if:` does not support regex
     natively. Use:
     ```
     if: github.event_name == 'pull_request' &&
         (github.base_ref == 'main' ||
          startsWith(github.base_ref, 'session-'))
     ```
   - Verify the configured check context name in
     `plugins/dso/docs/CONFIGURATION-REFERENCE.md` (`review.check_name`)
     matches the check actually published by the job. If the job publishes
     under a different name (e.g. via a status post), align them.
2. **Confirm the review pipeline tolerates session-base PRs.** The
   `llm-review` job and its downstream scripts assume `base_ref` to scope
   the diff. Audit `plugins/dso/scripts/` for any literal `main` /
   `origin/main` in review-range computation (overlaps with F-05; sequence
   F-05 first so the resolver is already in place).
3. **Add an end-to-end smoke test** under `.github/workflows/` (or
   `tests/integration/`) that:
   - Creates a story branch off a session branch.
   - Opens a PR into the session branch.
   - Asserts the configured `review.check_name` context appears on the PR
     within a bounded poll window.
   - The test can run on a fixture repo or against this repo with a
     short-lived branch pair.

#### Phase 2 — promote Ruleset preflight to blocking
4. **Update `plugins/dso/skills/sprint/SKILL.md:164–169`** (Phase A
   Ruleset preflight): when `dso.workflow=ci-pr`, a preflight failure
   must block sprint execution (return non-zero from the preflight
   helper; the sprint orchestrator halts and surfaces the error).
   - Preserve the advisory behavior when `dso.workflow=local`.
   - Provide an explicit override (`DSO_RULESET_PREFLIGHT_BYPASS=1` plus
     a non-empty `DSO_RULESET_PREFLIGHT_BYPASS_REASON`) modeled on the
     existing `DSO_*_ACTIVE_BYPASS_REASON` pattern in
     `pre-bash-functions.sh`. The bypass writes a JSONL audit line.
5. **Tighten the preflight checks themselves**:
   - Required: branch protection on `session-*` has the configured
     `review.check_name` listed in required checks.
   - Required: branch protection on `main` (or the resolved default
     branch from F-05) lists the same.
   - Required: PRs into both base-ref patterns can produce the check
     (i.e., the workflow's `if:` matches).
   - Fail with a precise message naming the missing rule and the `gh`
     command the user can run to fix it.

#### Phase 3 — wire the safety case end-to-end
6. **Update `INSTALL.md`** to remove the "KNOWN GAP" callout at L141 and
   replace it with the now-true claim that the check is produced on
   `session-*` PRs. Reference the preflight as the verification path.
7. **Update `plugins/dso/docs/CI-INTEGRATION.md`** with the new trigger
   matrix and the preflight contract.
8. **Add a property test** (workflow-level): in `ci-pr` mode, if the
   preflight passes, a synthetic story PR into a session branch will
   produce the configured check context. This is the contract test the
   safety case rests on.

#### Phase 4 — close the orchestrator-level loop
9. **Wire Phase E dispatch in `sprint/SKILL.md`** to require a passing
   preflight in `ci-pr` mode. Sequence: preflight in Phase A → Phase E
   refuses to dispatch sub-agents if the Phase A preflight verdict was
   not RECORD-pass. Use the existing event-log channel for the verdict
   so it survives compaction.

### Acceptance
- Synthetic story PR into a session branch produces the configured
  `review.check_name` context within the preflight's polling window.
- Sprint with `dso.workflow=ci-pr` and a deliberately-broken branch
  protection rule on `session-*` halts in Phase A with a precise
  remediation message (and does not dispatch Phase E sub-agents).
- `INSTALL.md` no longer carries the "KNOWN GAP" text; the post-mortem
  bug `576b-a6c7-3de3-4eef` is referenced as closed.
- Existing `llm-review` runs on PRs into `main` are unaffected
  (regression test on a `main`-base PR).

### Risk
High blast radius — these are the gates the safety case depends on, in
the workflow mode this repository itself uses. Mitigations:
- Stage Phase 1 and Phase 2 behind a feature flag
  (`review.session_base_enabled`, default false during rollout) so the
  widened trigger can be reverted independently of the preflight
  tightening.
- Land Phase 1 on a story branch, dogfood one sprint cycle, then enable
  Phase 2 in a follow-up.
- Keep the explicit human-approved bypass in Phase 2 so a misconfigured
  Ruleset cannot deadlock a release.

---

## Sequencing summary

1. **F-08** (30 min) — header rewrite + stale-term lint.
2. **F-06** (1–2 hr) — honor `tickets.directory` everywhere + regression
   test + literal guard.
3. **F-05** (½–1 day) — `resolve-default-branch.sh` + replace literals +
   trunk-fixture test.
4. **F-02** (1.5–2 days) — gate-tier doctrine + `_dso_gate_unavailable`
   helper + refactor three Tier A sites + Tier A integration tests.
5. **F-01** (1–3 days) — widen CI trigger, promote preflight to
   blocking, end-to-end smoke test, wire orchestrator gate, update docs.

Ordering constraints:
- **F-05 before F-01** — the widened `llm-review` job's review-range
  computation needs the resolver to work on non-`main` defaults.
- **F-02 before F-01** — F-02 establishes the gate-tier doctrine and the
  `_dso_gate_unavailable` / paired-bypass pattern. F-01's preflight
  tightening (Phase A Ruleset preflight → blocking) is the first
  application of that pattern outside `plugins/dso/hooks/`. Landing F-02
  first means F-01 inherits a proven helper instead of inventing a
  parallel mechanism.

## Tracking

Create one ticket per finding under the existing review-evaluation epic;
link via `--parent`. Use the standard story type for F-01, F-02, and
F-05 (each has multiple tasks); use task type for F-06 and F-08 (single
deliverable each). Verify via
`.claude/scripts/dso ticket list --status=in_progress` on session
resume.
