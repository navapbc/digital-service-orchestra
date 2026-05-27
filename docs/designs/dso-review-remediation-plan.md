# DSO Review Remediation Plan — F-01, F-05, F-06, F-08

Plan to implement four findings from the static review of the DSO agentic
workflow plugin. Findings are ordered by ascending blast-radius / effort so
that the trivial wins land first and the load-bearing change (F-01) lands on
a clean baseline.

## Scope

| ID   | Finding                                                              | Severity     | Est. effort |
|------|----------------------------------------------------------------------|--------------|-------------|
| F-08 | Stale "skeleton/future task" header in `merge-to-main-pr.sh`         | Low-Medium   | ~30 min     |
| F-06 | `tickets.directory` honored only partially in merge logic            | Medium       | 1–2 hr      |
| F-05 | Hard-coded `main` across merge/PR scripts                            | Medium       | ½–1 day     |
| F-01 | `ci-pr` mode skips local gates while session-branch CI check missing | **Critical** | 1–3 days    |

Out of scope for this plan (tracked separately): F-02 (fail-open
classification), F-03 (`SPRINT_SESSION_ID` singleton), F-04 (orchestration
typing), F-07 (telemetry auth).

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
4. **F-01** (1–3 days) — widen CI trigger, promote preflight to
   blocking, end-to-end smoke test, wire orchestrator gate, update docs.

F-05 must land before F-01 because the review-range computation in
`llm-review` needs the resolver to work on non-`main` defaults.

## Tracking

Create one ticket per finding under the existing review-evaluation epic;
link via `--parent`. Use the standard story type for F-01 and F-05 (each
has multiple tasks); use task type for F-06 and F-08 (single deliverable
each). Verify via `.claude/scripts/dso ticket list --status=in_progress`
on session resume.
