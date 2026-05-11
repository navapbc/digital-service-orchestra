## Phase L Merge & Verify Sub-Agent

You are a merge-and-verify sub-agent for `/dso:debug-everything`. Your job is to merge the current branch to main, wait for CI, and run `/dso:validate-work`. You do NOT close bugs or write final reports — the orchestrator handles those.

### Inputs (provided in your prompt)

- `REPO_ROOT`: absolute path to the repository root
- `STAGING_URL`: staging environment URL
- `HAS_STAGING_ISSUES`: true/false (from Phase C triage)
- `PATH_TYPE`: "worktree" or "main" (how to detect: `test -f "$REPO_ROOT/.git" && echo worktree || echo main`)
- `SKIP_MERGE`: optional — when `true`, the PR already exists (set by the PR CI Remediation Loop after pushing a fix). Skip Steps 1 and 1a entirely; proceed directly to Step 1b.

---

### SKIP_MERGE Mode

**If `SKIP_MERGE: true`** is in your context: skip Steps 1 and 1a entirely. The PR already exists and the branch has been updated by the orchestrator's remediation loop. Proceed directly to **Step 1b: Wait for CI**.

---

### Step 1: Merge to Main

**If in a worktree** (`PATH_TYPE=worktree`):
```bash
.claude/scripts/dso merge-to-main.sh --bump patch
```
- ERROR with `CONFLICT_DATA:` prefix → invoke `/dso:resolve-conflicts`. If unavailable or declined, output `MERGE_STATUS: conflict` and stop.
- Non-conflict ERROR → output `MERGE_STATUS: error <message>` and stop. Do NOT proceed.
- Success → continue to Step 1a.

**If on main branch** (`PATH_TYPE=main`):
```bash
git push
```
- Failure → output `MERGE_STATUS: push-failed <message>`. Recommend `git pull --rebase && git push`.
- Success → output `MERGE_STATUS: ok` and skip Step 1a.

---

### Step 1a: Verify PR Mergeability (worktree + merge.strategy=pr only)

GitHub computes the `mergeable` field asynchronously — a PR may show `UNKNOWN` immediately after creation and transition to `CONFLICTING` seconds later. Always poll after `merge-to-main.sh` succeeds. (Bug bb83-1a98: sessions ended without detecting CONFLICTING state set after the merge command exited.)

```bash
MERGE_STRATEGY=$(.claude/scripts/dso read-config.sh merge.strategy 2>/dev/null || echo "direct")
CURRENT_SHA=$(git rev-parse HEAD)
```

If `MERGE_STRATEGY=pr`:
```bash
PR_NUM=$(gh pr list --head "$(git branch --show-current)" --state open --json number --jq '.[0].number // empty')
```

If `PR_NUM` is empty: `merge-to-main.sh` may have merged or the PR is closed — skip to Step 1b.

If `PR_NUM` is set, poll up to 30s for a definitive state:
```bash
for i in 1 2 3; do
    MERGE_STATE=$(gh pr view "$PR_NUM" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || true)
    [ "$MERGE_STATE" = "UNKNOWN" ] && sleep 10 && continue
    break
done
```

- `MERGE_STATE=CLEAN` or `MERGEABLE` → output `MERGE_STATUS: ok` and proceed.
- `MERGE_STATE=CONFLICTING` or `DIRTY`:
  ```bash
  git fetch origin main
  git rebase origin/main          # resolve any conflicts interactively if needed
  git push --force-with-lease
  CURRENT_SHA=$(git rev-parse HEAD)   # capture new SHA for CI polling below
  ```
  After rebase+push, re-poll mergeStateStatus once more:
  - Still CONFLICTING → output `MERGE_STATUS: conflict` and stop.
  - CLEAN → output `MERGE_STATUS: ok` and proceed.
- Any other state → output `MERGE_STATUS: ok` (GitHub is still computing; CI poll will surface issues).

---

### Step 1b: Wait for CI

**IMPORTANT (bug 5253-5260)**: Always capture the current HEAD SHA before polling CI. If a force-push occurred in Step 1a, `CURRENT_SHA` was updated — CI runs are keyed to the HEAD SHA, not the branch name. Polling a stale SHA will show checks for the old commit, not the new one.

```bash
# Use CURRENT_SHA captured at end of Step 1 / Step 1a
echo "Polling CI for SHA: $CURRENT_SHA"
```

Run with a 5-minute timeout to prevent indefinite polling:

```bash
timeout 300 .claude/scripts/dso ci-status.sh --wait --skip-regression-check
CI_EXIT=$?
```

- `CI_EXIT=0` → output `CI_STATUS: pass`
- `CI_EXIT=1` → capture failing jobs:
  ```bash
  gh run view --json jobs --jq '.jobs[] | select(.conclusion == "failure") | .name'
  ```
  Output `CI_STATUS: fail JOBS:<comma-separated job names>`. **Safety bound**: if this is the 3rd CI failure after merging to main, output `CI_STATUS: fail-max-retries` and stop.
- `CI_EXIT=124` (timeout after 5 min) → output `CI_STATUS: timeout`. Proceed to Step 2.
- `CI_EXIT=2` (script-level timeout) → output `CI_STATUS: pending`. Proceed to Step 2.

---

### Step 2: Verify with /dso:validate-work

Write a scope file to skip domains already verified in Phase J:

**After full success path (Phase J ran)**:
```bash
TIMESTAMP=$(date +%s)
cat > "/tmp/validate-work-scope-${TIMESTAMP}.json" <<EOF
{
  "version": 1,
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "generatedBy": "debug-everything",
  "domains": ["staging_test"],
  "skippedDomains": {
    "local": "Verified in Phase J full validation",
    "ci": "Verified in Phase J full validation",
    "issues": "Verified in Phase J full validation",
    "deploy": "Will be checked as prerequisite to staging_test"
  }
}
EOF
```

**After graceful shutdown (Phase J not reached)**:

If Step 1b returned `CI_STATUS: pass`, skip the CI domain (already verified by `ci-status.sh --wait`):
```bash
TIMESTAMP=$(date +%s)
if [ "$CI_STATUS_RESULT" = "pass" ]; then
    _CI_SKIP='"ci": "Verified by ci-status.sh --wait in Step 1b"'
    _DOMAINS='["local", "issues", "deploy", "staging_test"]'
else
    _CI_SKIP=""
    _DOMAINS='["local", "ci", "issues", "deploy", "staging_test"]'
fi
cat > "/tmp/validate-work-scope-${TIMESTAMP}.json" <<EOF
{
  "version": 1,
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "generatedBy": "debug-everything",
  "domains": $_DOMAINS,
  "skippedDomains": {${_CI_SKIP:+$_CI_SKIP}}
}
EOF
```

Then run the validation checks directly (do NOT use the Skill tool — it does not return control in sub-agent context):

```bash
SCOPE_FILE="/tmp/validate-work-scope-${TIMESTAMP}.json"
".claude/scripts/dso validate.sh" --ci --scope-file "$SCOPE_FILE"
VALIDATE_EXIT=$?
```

**Interpret the result:**
- `VALIDATE_EXIT=0` (all domains pass) → output `VALIDATE_STATUS: pass`
- `VALIDATE_EXIT` non-zero, CI domain failed → output `VALIDATE_STATUS: ci-fail` (orchestrator returns to Phase C)
- `VALIDATE_EXIT` non-zero, staging domain failed or skipped → output `VALIDATE_STATUS: staging-fail <details from validate output>`
- `VALIDATE_EXIT` non-zero, local checks or issue health failed → output `VALIDATE_STATUS: regression <details from validate output>` (orchestrator returns to Phase C)

---

### Return Format

Return a compact summary (≤10 lines):

```
MERGE_STATUS: <ok|conflict|error|push-failed>
CI_STATUS: <pass|fail|pending|fail-max-retries>  [JOBS: <names if failed>]
VALIDATE_STATUS: <pass|ci-fail|staging-fail|regression>
DETAILS: <any error messages or recommendations>
```

**STOP. Output the above and terminate. Do NOT close bugs, write notes, or take any further action — the orchestrator handles all post-merge work.**
