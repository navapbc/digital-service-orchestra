# Rulesets rollback runbook

Captures the pre-PATCH state of the two GitHub Rulesets affected by the staged-* promotion model rollout (PR-B), and documents the exact commands to restore prior state if the rollout wedges the repo.

## When to use this runbook

Apply if any of these conditions hold after the live PATCHes documented in PR-B:

1. PRs to main are blocked by a check name that doesn't appear in any workflow's job (typo in `required-checks.txt` made it past validation).
2. `gh pr merge` against `staged-*` PRs hangs indefinitely with no available bypass.
3. `provision-ruleset.sh` re-provisioning produces 422 from GitHub's Rulesets API on the `required_workflows` rule.
4. Admins lose the ability to bypass-merge on any PR.

If none of these hold, do not roll back — the workflow may simply need a verification PR to confirm functioning.

## Rollback artifacts

The pre-PATCH state of both rulesets is captured in:

- `rulesets/15629023.before.json` — main ruleset ("DSO CI Enforcement")
- `rulesets/16961402.before.json` — sub-PR ruleset ("DSO Sub-PR Review Enforcement")

These files are committed to source control as the source of truth for the rollback. Do NOT edit them — the restore commands below depend on bit-identical replay.

## Sequence

### Phase 1: assess scope

```bash
# What's the current state of each ruleset?
gh api repos/navapbc/digital-service-orchestra/rulesets/15629023 > /tmp/15629023.current.json
gh api repos/navapbc/digital-service-orchestra/rulesets/16961402 > /tmp/16961402.current.json

# Diff against the captured pre-PATCH state
diff <(jq -S . rulesets/15629023.before.json) <(jq -S . /tmp/15629023.current.json) | head -40
diff <(jq -S . rulesets/16961402.before.json) <(jq -S . /tmp/16961402.current.json) | head -40
```

If the diffs show only the expected post-PATCH changes (sub-PR ruleset moved to `required_workflows` + `include=staged-*` + bypass_mode `pull_request`; main ruleset added `check-staged-head` to required_status_checks), the system is in the planned state — diagnose the actual symptom before rolling back.

### Phase 2: roll back sub-PR ruleset (16961402)

```bash
# Full-replace the sub-PR ruleset to its pre-PATCH state.
# Extract only the mutable fields from the captured JSON (the API rejects
# readonly fields like id, source, source_type, node_id, _links, created_at,
# current_user_can_bypass on PUT).
jq '{
  name,
  target,
  enforcement,
  conditions,
  rules,
  bypass_actors
}' rulesets/16961402.before.json > /tmp/16961402.restore-payload.json

gh api -X PUT repos/navapbc/digital-service-orchestra/rulesets/16961402 \
  --input /tmp/16961402.restore-payload.json
```

Verify:
```bash
gh api repos/navapbc/digital-service-orchestra/rulesets/16961402 \
  --jq '{name, enforcement, include: .conditions.ref_name.include, rules: [.rules[].type], bypass: .bypass_actors}'
```

### Phase 3: roll back main ruleset (15629023)

```bash
jq '{
  name,
  target,
  enforcement,
  conditions,
  rules,
  bypass_actors
}' rulesets/15629023.before.json > /tmp/15629023.restore-payload.json

gh api -X PUT repos/navapbc/digital-service-orchestra/rulesets/15629023 \
  --input /tmp/15629023.restore-payload.json
```

Verify:
```bash
gh api repos/navapbc/digital-service-orchestra/rulesets/15629023 \
  --jq '{name, enforcement, required_checks: [.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context]}'
```

The `required_checks` list should NOT include `check-staged-head` after rollback.

### Phase 4: drop the check-staged-head workflow file

```bash
# On the branch that introduced PR-B's changes, revert .github/workflows/check-staged-head.yml.
git revert <PR-B-merge-sha> -- .github/workflows/check-staged-head.yml
```

Or open a small revert PR if reverting the whole merge isn't desired.

## Pre-flight gate (run BEFORE applying the forward PATCH)

These assertions MUST pass before applying the forward PATCHes documented in PR-B's body. Add them to the operator checklist:

```bash
# 1. Confirm both pre-PATCH artifacts exist
test -s rulesets/15629023.before.json
test -s rulesets/16961402.before.json

# 2. Confirm the workflow file exists on main (or in the PR-B merge commit)
test -f .github/workflows/check-staged-head.yml

# 3. Confirm required-checks.txt lists check-staged-head
grep -q '^check-staged-head$' .github/required-checks.txt

# 4. Confirm gh has admin scope
gh auth status -t 2>&1 | grep -qE 'admin:org|admin:repo|repo admin'
```

If any assertion fails, do not proceed.

## Post-PATCH validation (Phase 3a smoke test from the plan)

After PATCHing the main ruleset (3a, BEFORE PATCHing sub-PR ruleset 3b):

```bash
# Open a throwaway docs-only PR from a non-staged-* head against main.
# Expected: check-staged-head fails the PR. Do NOT merge this PR — close it.
gh pr create --base main --head <some-non-staged-branch> --title 'smoke: verify check-staged-head fails' --body 'Throwaway. Close, do not merge.' --draft
```

After PATCHing the sub-PR ruleset (3b):

```bash
# Open a small PR from any branch into a fresh staged-test-rollout-1 branch.
# Expected: review-sub-pr workflow fires (required_workflows rule) and must
# pass before merge. Bypass should be available at PR-merge time only.
```

## Known failure modes

- **`gh api -X PUT` returns 422 with "required_workflows is invalid"**: the workflow `repository_id` or `path` doesn't match an existing workflow file on the named `ref`. Verify the workflow file exists at `.github/workflows/review-sub-pr.yml` on the `ref` (default `refs/heads/main`). Re-fetch the workflow ID via `gh api repos/navapbc/digital-service-orchestra/actions/workflows --jq '.workflows[] | select(.path == ".github/workflows/review-sub-pr.yml") | .id'`.
- **`check-staged-head` is required but doesn't appear in PR check list**: the workflow's `on:` filter is `pull_request.branches: [main]` — if the PR's base isn't main, the workflow never fires and the check is never reported. The required_status_checks rule would then deadlock the PR. Verify the PR base is `main`.
