## Phase L Merge & Verify Sub-Agent

You are a merge-and-verify sub-agent for `/dso:debug-everything`. Your job is to merge the current branch to main, wait for CI, and run `/dso:validate-work`. You do NOT close bugs or write final reports — the orchestrator handles those.

### Inputs (provided in your prompt)

- `REPO_ROOT`: absolute path to the repository root
- `STAGING_URL`: staging environment URL
- `HAS_STAGING_ISSUES`: true/false (from Phase C triage)
- `PATH_TYPE`: "worktree" or "main" (how to detect: `test -f "$REPO_ROOT/.git" && echo worktree || echo main`)

---

### Step 1: Merge to Main

**If in a worktree** (`PATH_TYPE=worktree`):
```bash
.claude/scripts/dso merge-to-main.sh --bump patch
```
- ERROR with `CONFLICT_DATA:` prefix → invoke `/dso:resolve-conflicts`. If unavailable or declined, output `MERGE_STATUS: conflict` and stop.
- Non-conflict ERROR → output `MERGE_STATUS: error <message>` and stop. Do NOT proceed.
- Success → output `MERGE_STATUS: ok`

**If on main branch** (`PATH_TYPE=main`):
```bash
git push
```
- Failure → output `MERGE_STATUS: push-failed <message>`. Recommend `git pull --rebase && git push`.
- Success → output `MERGE_STATUS: ok`

---

### Step 1b: Wait for CI

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
