---
id: dso-gego
status: open
deps: [dso-spfe]
links: []
created: 2026-03-22T17:44:41Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-txt8
---
# Implement opus arch reviewer dispatch: inject inline findings, write authoritative reviewer-findings.json

Update REVIEW-WORKFLOW.md Step 4 to document the sequential opus architectural reviewer dispatch that occurs after all 3 parallel sonnet reviewers complete.

TDD REQUIREMENT: Tests from dso-spfe must be RED before this task is implemented.

Implementation in plugins/dso/docs/workflows/REVIEW-WORKFLOW.md, Step 4 Deep Tier subsection (appended after sonnet dispatch):
1. After all 3 sonnet agents complete and temp files are saved:
   a. Read findings from each temp file:
      FINDINGS_A=$(python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings-a.json')); print(json.dumps(d['findings']))")
      FINDINGS_B=$(python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings-b.json')); print(json.dumps(d['findings']))")
      FINDINGS_C=$(python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings-c.json')); print(json.dumps(d['findings']))")
   b. Dispatch dso:code-reviewer-deep-arch (model: opus) with prompt containing:
      - DIFF_FILE path
      - REPO_ROOT
      - STAT_FILE content
      - Issue context (if any)
      - Inline specialist findings block (matching the format specified in code-reviewer-deep-arch.md):
        === SONNET-A FINDINGS (correctness) ===
        <FINDINGS_A>
        === SONNET-B FINDINGS (verification) ===
        <FINDINGS_B>
        === SONNET-C FINDINGS (hygiene/design) ===
        <FINDINGS_C>
   c. The deep-arch agent writes the final authoritative reviewer-findings.json
   d. Orchestrator reads REVIEWER_HASH from deep-arch output and passes to record-review.sh

2. Update Step 5 (Record Review) to note that for deep tier, REVIEWER_HASH comes from the opus agent output

File impact:
- Edit: plugins/dso/docs/workflows/REVIEW-WORKFLOW.md

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Tests from dso-spfe now PASS (GREEN state)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh 2>&1 | grep "test_deep_arch_reviewer_dispatched_after_sonnets" | grep -q "PASS"
- [ ] REVIEW-WORKFLOW.md documents code-reviewer-deep-arch dispatch after sonnet agents
  Verify: grep -q "code-reviewer-deep-arch" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md documents SONNET-A FINDINGS, SONNET-B FINDINGS, SONNET-C FINDINGS inline injection format
  Verify: grep -q "SONNET-A FINDINGS" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md Step 5 notes REVIEWER_HASH comes from opus agent for deep tier
  Verify: grep -A5 "deep tier" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md | grep -q "REVIEWER_HASH"

## Notes

**2026-03-22T19:17:34Z**

CHECKPOINT 0/6: SESSION_END — Not started. Resume with /dso:sprint w21-ykic --resume
