---
id: w22-uyhe
status: in_progress
deps: [w22-t2nm, w22-8g9v]
links: []
created: 2026-03-22T20:01:55Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-nv42
---
# Implement size-based model upgrade and rejection branching in REVIEW-WORKFLOW.md

Add Step 3 post-classifier branching to `plugins/dso/docs/workflows/REVIEW-WORKFLOW.md` to implement model upgrade (300+ lines), review rejection (600+ lines), and re-review exemption from size limits.

**Implementation steps**:

1. **Read `size_action` and `is_merge_commit` from classifier output** — after the existing `REVIEW_TIER` extraction in Step 3, add:
   ```bash
   SIZE_ACTION=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_action","none"))' 2>/dev/null || echo "none")
   IS_MERGE=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d.get("is_merge_commit",False)).lower())' 2>/dev/null || echo "false")
   DIFF_SIZE_LINES=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("diff_size_lines",0))' 2>/dev/null || echo "0")
   ```

2. **Add `REVIEW_PASS_NUM` guard** — size limits apply ONLY to initial review dispatch (pass 1). Re-review passes (pass ≥ 2) in the Autonomous Resolution Loop must never be rejected:
   ```bash
   REVIEW_PASS_NUM="${REVIEW_PASS_NUM:-1}"
   ```
   Size action branching below is wrapped in `if [[ "$REVIEW_PASS_NUM" -le 1 ]]; then ... fi`

3. **Model upgrade branch** (size_action == "upgrade" and pass 1):
   ```bash
   if [[ "$SIZE_ACTION" == "upgrade" && "$REVIEW_PASS_NUM" -le 1 ]]; then
       # Upgrade model to opus at current tier's checklist scope
       REVIEW_AGENT_OVERRIDE="dso:code-reviewer-deep-arch"  # opus model
       echo "SIZE_UPGRADE: diff has ${DIFF_SIZE_LINES} scorable lines — upgrading to opus reviewer at ${REVIEW_TIER} tier scope"
   fi
   ```
   Note: `REVIEW_AGENT_OVERRIDE` takes precedence over `REVIEW_AGENT` when set; the dispatch in Step 4 must check `REVIEW_AGENT_OVERRIDE` first.

4. **Rejection branch** (size_action == "reject" and pass 1):
   ```bash
   if [[ "$SIZE_ACTION" == "reject" && "$REVIEW_PASS_NUM" -le 1 ]]; then
       SPLITTING_GUIDE_PATH="plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md"
       echo "REVIEW_REJECTED: diff has ${DIFF_SIZE_LINES} scorable lines (≥600 threshold)."
       echo "Large diffs exhaust reviewer context and degrade review quality."
       echo "Split your changes into smaller commits before re-running review."
       echo "Guidance: ${SPLITTING_GUIDE_PATH}"
       echo "REVIEW_RESULT: rejected"
       exit 1
   fi
   ```

5. **Update Step 4 dispatch** — add a note that when `REVIEW_AGENT_OVERRIDE` is set (upgrade case), dispatch uses `REVIEW_AGENT_OVERRIDE` instead of `REVIEW_AGENT` for single-agent tiers; for deep tier, the upgrade means an additional opus pass is added after the 3 parallel agents.

6. **Document the re-review exemption** — add a comment in Step 3 explaining that `REVIEW_PASS_NUM` must be set by the Autonomous Resolution Loop caller (REVIEW-WORKFLOW.md already has this loop; find where it increments pass number and ensure `REVIEW_PASS_NUM` is exported).

**TDD Requirement**: Depends on RED test task w22-8g9v. Before implementing, confirm all 5 RED tests fail. After implementation, all 5 must pass GREEN. Run: `bash tests/workflows/test-review-workflow-size-thresholds.sh`.

**Files**:
- `plugins/dso/docs/workflows/REVIEW-WORKFLOW.md` (Edit — Step 3 extension and Step 4 override note)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] REVIEW-WORKFLOW.md Step 3 contains `size_action` extraction logic
  Verify: grep -q "size_action\|SIZE_ACTION" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md Step 3 contains rejection branch with `large-diff-splitting-guide.md` reference
  Verify: grep -q "large-diff-splitting-guide" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md Step 3 contains `REVIEW_PASS_NUM` guard (re-review exemption)
  Verify: grep -q "REVIEW_PASS_NUM" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] All 5 RED tests from task w22-8g9v now pass GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/workflows/test-review-workflow-size-thresholds.sh 2>&1 | grep -v "^FAIL" | grep -q "PASS\|passed"
- [ ] `.test-index` RED marker for REVIEW-WORKFLOW.md tests is removed (all tests pass)
  Verify: grep "test-review-workflow-size-thresholds.sh" $(git rev-parse --show-toplevel)/.test-index | grep -v "\["
- [ ] REVIEW-WORKFLOW.md Step 4 dispatch block reads `REVIEW_AGENT_OVERRIDE` before `REVIEW_AGENT` (gap analysis finding: upgrade path otherwise silently fails)
  Verify: grep -q "REVIEW_AGENT_OVERRIDE" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md && grep -A5 "REVIEW_AGENT_OVERRIDE" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md | grep -q "REVIEW_AGENT"
- [ ] Rejection branch outputs `REVIEW_RESULT: rejected` line before `exit 1` (gap analysis finding: callers must parse structured output, not only exit code)
  Verify: grep -A3 "size_action.*reject\|SIZE_ACTION.*reject" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md | grep -q "REVIEW_RESULT"
