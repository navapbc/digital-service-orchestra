# Workflow Stability Plan v3 — Handoff

> **⛔ SUPERSEDED (2026-05-31) by `workflow-stability-plan-v4-handoff.md`.**
> A ground-truth re-audit (2 opus review rounds + live `gh` probing) found that this plan's
> central premise (Q3: "live ruleset drifted off-canonical; broaden include to `~ALL`/exclude-main")
> is **false and dangerous** — `["refs/heads/staged-*"]` is the deliberately-chosen canonical shape;
> provisioning `~ALL` would fail invariant I1 and block merges to main (when the rulesets PAT is
> provisioned) or let drift pass undetected (when it is not). The false premise was read from a
> **stale header comment** in `test-branch-pattern-alignment.sh`, not the test's assertion body.
> Stories 1 & 3 were also already shipped. **Do not execute this plan.** See v4 for the corrected
> assumptions, scope, and rationale. This document is retained unmodified below for historical record.

**Date**: 2026-05-31
**Status**: Plan finalized after 3 iterations + prior-art research + 2 opus reviews + diagnostic phases. Ready for execution in a fresh session.
**Scope**: Final remediation for OVER_BOUND wedges, provenance gaps, and admin-bypass audit holes in the two-tier CI review workflow.

## Goal

Achieve a workflow where:
1. Every code change is reviewed before reaching main.
2. The workflow doesn't block on false positives or process bugs.

The plan must be **final**. Prior iterations shipped and revealed new failure modes within days. This iteration was reviewed with explicit instruction to find the next failure mode before shipping; 7 must-fixes were surfaced and incorporated.

## Threat model context (load-bearing)

- LLM agents (Claude Code sessions) have a classic GitHub PAT with `repo` scope but NOT admin
- Hooks like `hook_no_force_merge` enforce local restrictions on agent bash commands
- Ruleset configurations are the durable trust boundary (NOT hooks, NOT docs)
- Capability containment principle: agents detect, humans mutate; agents propose, humans approve

## Design decisions and rationale

Four questions were resolved through tradeoff analysis informed by prior-art research across 9+ projects (Kubernetes Tide, Bors-NG, Mergify, GitHub Merge Queue, Linux kernel, Chromium CQ, OpenStack Zuul, Graphite, Rust bors rollups) and a second round on false-positive handling (40+ tools: SonarQube, Snyk, GitHub Code Scanning, Coverity, Semgrep, OWASP Dependency-Check, Kubernetes Prow, Mergify flaky-test pattern, etc.).

**Q1 — How should the per-finding defense store integrate with the merge gate?**
Decision: **Option B — Companion check `review-defenses-cleared`** (separate required CI check that reports SUCCESS only if every blocking finding is defended-or-resolved).
Rationale: matches Kubernetes Prow's `/override` pattern + GitHub Code Scanning's delegated dismissal. Separates raw LLM verdict from defense-cleared verdict; defenses remain auditable.

**Q2 — Sub-PR ruleset `bypass_mode` setting?**
Decision: **Option A — Keep `bypass_mode: pull_request`** (current live state).
Rationale: capability containment. UI-click bypass is human-only; LLM agents with PAT cannot trigger it programmatically. Diverges from industry "always" mode but justified by our novel threat model (autonomous LLM agents with PAT access).

**Q3 — Ruleset scope drift (live=`["staged-*"]` vs design test=`["~ALL"], exclude:["main"]`)?**
Decision: **Option A — Bring live to match design test** (broad coverage).
Rationale: defense in depth + design test was authoritative; live state drifted off-canonical. Provisioning is one-time human action; ongoing drift detection runs in CI.

**Q4 — Integration LLM review (PR2 staged→main)?**
Decision: **Option B with config toggle** — keep required by default; add `integration_review.enabled` toggle for emergency conversion to no-op.
Rationale: empirical evidence (PR 509) shows integration review catches real findings sub-PR review misses. Industry retires it because human re-review is expensive; our LLM cost ($0.10/30s) inverts the calculus. Toggle provides escape valve without code change.

## Live state facts (verified by opus reviewer)

- Live ruleset 16961402 `conditions.ref_name.include`: `["refs/heads/staged-*"]`
- Live ruleset 16961402 `bypass_actors[0].bypass_mode`: `pull_request` (matches Q2 decision)
- `verify-session-provenance.sh:597-599` G3 check-name literal: `'review-sub-pr' in r.get('name', '') or 'llm-review' in r.get('name', '')`
- `verify-session-provenance.sh:502-511`: A3a/A3b/A1 filters as documented
- `tests/scripts/test-branch-pattern-alignment.sh` asserts `include: ["~ALL"], exclude: ["refs/heads/main"]` via dry-run of `provision-ruleset.sh`
- `.github/workflows/ruleset-design-invariants.yml`: **DOES NOT EXIST** (must be created in Story 1)
- `docs/handoff/archive/`: **DOES NOT EXIST** (must be created in Phase 0)
- `docs/contracts/review-defenses.md`: defense_text max 4096 codepoints; no current minimum (Story 2 R4 adds 80-char minimum)
- `plugins/dso/scripts/mirror-defenses-to-pr.sh`: 26-line thin wrapper around `review-github-defense-store.sh` (R4 must target the latter, NOT the wrapper)
- `plugins/dso/config/dso-config.reference.conf` pattern: `<namespace>.<key>=true|false` (e.g., `test_quality.enabled=true`)

## The plan

### Phase 0 — Pre-flight (mixed agent + human)

**Agent tasks**:
1. Reconcile stale handoff docs. Add this header at the top of each:
   ```
   > **HISTORICAL** — captured during a prior planning iteration. Live system state has evolved.
   > For current architecture, see `docs/contracts/sub-pr-enforcement.md` (if exists) and this handoff doc.
   ```
   Apply to: `docs/handoff/llm-review-pipeline-hardening-handoff.md`, `docs/handoff/llm-review-enforcement-handoff.md`.
   Move both to `docs/handoff/archive/` (create directory; `git add` it explicitly).

2. Document Phase 0 smoke test pass criteria for human:
   - Open a sub-PR in browser (any PR targeting a `staged-*` branch with `bypass_mode: pull_request` ruleset)
   - User must verify: "Merge without waiting for checks" button visible to admin role under our SSO config
   - Pass: button visible → architecture viable, proceed
   - Fail: button hidden → architecture needs reconsideration, escalate before proceeding

**Human task** (USER, in browser):
- Execute the smoke test
- Report back outcome before Story 1 proceeds

### Story 1 — Ruleset scope provisioning + create the missing workflow

**Addresses MUST FIX #1 and #7.**

**Agent tasks**:
1. Create `.github/workflows/ruleset-design-invariants.yml`:
   ```yaml
   name: ruleset-design-invariants
   on:
     pull_request:
       branches: [main]
     schedule:
       - cron: '0 6 * * *'  # daily 06:00 UTC drift detection
     workflow_dispatch:
   permissions:
     contents: read
   jobs:
     ruleset-design-invariants:
       runs-on: ubuntu-latest
       timeout-minutes: 3
       steps:
         - uses: actions/checkout@<pinned-sha>
           with:
             persist-credentials: false
         - name: Run invariant assertions
           env:
             GH_TOKEN: ${{ secrets.DSO_RULESETS_READ_TOKEN || secrets.GITHUB_TOKEN }}
             GH_REPO: ${{ github.repository }}
           run: |
             set +e
             bash tests/scripts/test-ruleset-design-invariants.sh
             rc=$?
             if [ "$rc" -eq 78 ]; then
               echo "::warning::Ruleset invariants precondition not met (likely missing DSO_RULESETS_READ_TOKEN)"
               exit 0
             fi
             exit $rc
   ```
2. Add `ruleset-design-invariants` to `.github/required-checks.txt` if not present
3. Update `CI-INTEGRATION.md`:
   - Document the new workflow + cron schedule
   - Document the provisioning step (human-only action)
   - Cross-reference Story 3's invariant assertion

**Human task** (USER):
- Run `bash plugins/dso/scripts/onboarding/provision-ruleset.sh` once via admin credentials
- This brings live ruleset 16961402 from `include: ["refs/heads/staged-*"]` to `include: ["~ALL"], exclude: ["refs/heads/main"]`
- After running: re-run `tests/scripts/test-ruleset-design-invariants.sh` locally to verify alignment

### Story 2 — Companion check `review-defenses-cleared`

**Addresses MUST FIX #2, #3, #4.**

**MUST FIX #2 — Target the correct file**:
- 80-char `defense_text` minimum lands in `plugins/dso/scripts/review-github-defense-store.sh` (the actual validation logic), NOT in `mirror-defenses-to-pr.sh` (the wrapper).
- Update `docs/contracts/review-defenses.md` Failure Contract table to add the floor.

**MUST FIX #3 — HMAC-signed retroactive idempotency marker** (was forgeable):
- CI runner has access to `DSO_AUDIT_HMAC_KEY` secret (PAT does NOT)
- Marker format: `DSO-Audit-Retroactive: <reviewer-hash> <hmac-sha256-of-{pr-id,reviewer-hash,timestamp}>`
- Sweep validates HMAC before treating the marker as authoritative
- Agent without the secret cannot post a valid marker → containment maintained
- Key-rotation runbook required (file as follow-up ticket)

**MUST FIX #4 — Ordering + absent-findings.json behavior**:
- `review-defenses-cleared` job declares `needs: llm-review` in `ci.yml` (runs after)
- Behavior when `reviewer-findings.json` is absent:
  - If dispatcher output JSON has `skip_reason` set (review was skipped because all commits provenanced) → SUCCESS
  - If `skip_reason` absent and findings.json absent → FAILURE (review failed before writing)
  - Discriminator: parse dispatcher output for `skip_reason` field

**Other Story 2 work**:
- Add new `review-defenses-cleared` job to `ci.yml`:
  - Reads `reviewer-findings.json` from artifacts
  - Reads defense comments via `review-defense-store.sh`'s load function
  - For each critical/important/fragile finding: SUCCESS if defended OR resolved; FAIL otherwise
  - Validate every defense_text is ≥80 chars
- Add `review-defenses-cleared` to `.github/required-checks.txt`
- Extend `verify-session-provenance.sh:597-599` G3 literal to include `'review-defenses-cleared'`:
  ```python
  if any(name in r.get('name', '') for name in ('review-sub-pr', 'llm-review', 'review-defenses-cleared')):
  ```
- Redesign `FP-RECOVERY-WORKFLOW.md` Step 5 for two scenarios:
  - **S1 (proactive)**: agent dispatches manual opus review, records defenses via mirror-defenses-to-pr.sh, generates the **PR URL** and instructs user: "Open <github.com/.../pull/N> and click 'Merge without waiting for checks' if you've reviewed the audit." **NO CLI bypass** (capability containment from Q2).
  - **S2 (retroactive)**: agent encounters MERGED PR with bypass signature (review-sub-pr FAILURE + no valid `DSO-Audit-Retroactive:<HMAC>` comment); posts audit comment retroactively WITH HMAC-signed marker. Idempotency check validates HMAC before treating marker as authoritative.
- Update `COMMIT-WORKFLOW.md` with S2 retroactive sweep logic (runs on any agent encountering a recently-merged PR)

**Pseudocode for `review-defenses-cleared` job**:
```
1. Locate reviewer-findings.json (from llm-review artifacts)
   if absent:
     - parse dispatcher output for skip_reason
     - if skip_reason present → exit 0 SUCCESS
     - else → exit 1 FAILURE "review-findings missing without skip reason"
2. Load defenses for PR via review-defense-store.sh::load_for_region
3. For each finding in findings:
   - if severity in (critical, important, fragile):
     - if finding.id resolved (status field) → CLEARED
     - elif finding.id in defenses:
       - if len(defense_text) < 80 → FAIL "defense too short"
       - else → CLEARED
     - else → FAIL "unaddressed blocking finding"
4. Emit structured log: ::notice::defenses_cleared decision=<x> findings=<n> defended=<m>
5. Exit 0 if all blocking findings CLEARED; else exit 1
```

### Story 3 — Bypass model invariant

- Add assertion to `tests/scripts/test-ruleset-design-invariants.sh`:
  ```bash
  assert_eq "I8_sub_pr_bypass_mode_pull_request" \
    "pull_request" \
    "$(jq -r '.bypass_actors[0].bypass_mode // ""' <<<"$SUB_PR_RULESET")"
  ```
- Live state already matches — this is invariant-lock, not state change
- New section in `CI-INTEGRATION.md` documenting the capability-containment rationale (cross-reference Q2 decision)
- Update `FP-RECOVERY-WORKFLOW.md` to direct user to web UI rather than CLI

### Story 4 — Integration LLM review escape valve

**Addresses MUST FIX #5 (reference-config update).**

- Add to `plugins/dso/config/dso-config.reference.conf`:
  ```
  # Integration LLM review on PR2 (staged→main). Default true.
  # Flip to false in emergencies (escalating FP rate, persistent OVER_BOUND).
  # Flipping triggers a structured event log line for Story 5 observability.
  integration_review.enabled=true
  ```
- Modify `ci.yml` `llm-review` job:
  ```yaml
  - id: integration_review_cfg
    run: |
      val=$(grep -E '^integration_review\.enabled=' .claude/dso-config.conf 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo "true")
      echo "enabled=${val:-true}" >> $GITHUB_OUTPUT
  - if: steps.integration_review_cfg.outputs.enabled == 'false'
    run: |
      echo "::notice::integration_review_disabled=true reason=config_toggle"
      exit 0
  ```
- Keep `llm-review` in `required-checks.txt` (avoid required-never-reports deadlock)
- Document in `CI-INTEGRATION.md`: when/how to flip; the structured event log enables Story 5's signal

### Story 5 — Observability (REDUCED scope: 80% value at 20% cost)

**MUST KEEP**:
1. Scheduled run of ruleset-design-invariants assertion (in Story 1's workflow)
2. Structured log lines at every decision point in `review-defenses-cleared` job:
   ```
   echo "::notice::defenses_cleared decision=<cleared|blocked> findings=<n> defended=<m> skipped=<k>"
   ```
3. Nightly bypass-signature sweep (workflow_dispatch + cron):
   - Lists PRs merged via `bypass_mode: pull_request` action in last 24h
   - Posts comment to a designated audit issue with PR list

**DEFER to follow-up epic**:
- Defense-accumulation-per-week reporter
- FP-rate signal on review-sub-pr with thresholds
- Centralized dashboard / metrics endpoint

### Gap 2 fix (parallel, independent)

**Addresses MUST FIX #6 (concrete candidate-type discrimination).**

Refactor `verify-session-provenance.sh` lines 476-511 to introduce explicit candidate-type discrimination:

1. Pass new parameter `--candidate-type=<self|sub-pr>` to the inner Python script
2. Apply A1 (PR_NUMBER self-exclusion) and A3a (head.sha self-exclude) ONLY when `candidate-type == self`
3. For `candidate-type == sub-pr`: skip A1 and A3a; proceed to A2/A3b/G3 evaluation
4. The bash wrapper determines candidate type from `covering_pr_number == current_PR_NUMBER`:
   - Match → candidate-type=self (current PR cannot cover its own commits)
   - No match → candidate-type=sub-pr (sub-PR coverage is valid)
5. A1 remains load-bearing for push-event self-review (bug 8a77) — do NOT remove globally, just scope to self case

Tests required:
- Rebase scenario (PR head SHA changed mid-flight)
- Squash-merge scenario (single-parent merge commit)
- Cherry-pick scenario (commit copied to new branch outside sub-PR flow)

### Sequencing

```
Phase 0 (agent + human): handoff doc reconciliation + smoke test
  ↓
Story 1 (agent creates workflow; HUMAN runs provisioner)
  ↓ (Story 1 must complete before Story 2 enforcement is meaningful)
Story 3 (invariant assertion; locks current good state — cheap)
  ↓
Story 2 (companion check with MUST FIXES #2, #3, #4)
  ↓ parallel ↓ parallel ↓
Story 4 (toggle)   Gap 2 fix   Story 5 MINIMUM
```

### Residual risk

With v3 fixes applied: ~15% probability of new failure mode in 30 days (vs 30% v2, 70% v1).

**Primary residual risk**: HMAC secret leak. Key-rotation runbook required before/with Story 2. File as separate ticket: `<bug-id>` "DSO_AUDIT_HMAC_KEY rotation procedure".

## Files / scripts referenced

- `tests/scripts/test-branch-pattern-alignment.sh` — design test for ruleset shape
- `tests/scripts/test-ruleset-design-invariants.sh` — invariant assertions
- `plugins/dso/scripts/verify-session-provenance.sh:476-511, 597-599` — verifier filters
- `plugins/dso/scripts/onboarding/provision-ruleset.sh` — provisioner (human-only)
- `plugins/dso/scripts/review-github-defense-store.sh` — defense store (R4 target)
- `plugins/dso/scripts/mirror-defenses-to-pr.sh` — thin wrapper (NOT R4 target)
- `plugins/dso/docs/contracts/review-defenses.md` — defense contract
- `plugins/dso/docs/workflows/FP-RECOVERY-WORKFLOW.md` — Step 5 redesign target
- `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md` — S2 retroactive sweep target
- `plugins/dso/docs/CI-INTEGRATION.md` — multiple doc updates
- `plugins/dso/config/dso-config.reference.conf` — Story 4 toggle key
- `.github/workflows/ci.yml` — `llm-review` job + new `review-defenses-cleared` job
- `.github/required-checks.txt` — add `review-defenses-cleared`, `ruleset-design-invariants`
- `.github/workflows/ruleset-design-invariants.yml` — Story 1 creates this

## Open questions for the executing session

1. What naming convention should we use for the audit issue that the nightly bypass-signature sweep posts to? Suggest: a pinned issue with title `Workflow Audit: Daily Bypass Sweep`.
2. Should `review-defenses-cleared` be subject to itself in some recursive case? (Probably not — but think through carefully when implementing.)
3. The structured log lines in Story 5: should they emit to `::notice::` (GitHub Actions log) or also write to a metrics file (e.g., `/tmp/dso-metrics.jsonl`)?

## What to NOT do in the executing session

- Do not retire integration LLM review (Q4 decision was Option B; toggle is the only mechanism)
- Do not change `bypass_mode` from `pull_request` to `always` (Q2 decision)
- Do not edit the LLM review prompts (`reviewer-base.md`) — that's a separate concern
- Do not invent new audit signals beyond `DSO-Audit-Retroactive:<hash> <HMAC>` and `DSO-Defenses-Cleared-Skipped:<reason>`
