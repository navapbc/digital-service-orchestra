---
id: dso-gego
status: in_progress
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

<!-- note-id: jdmyntaj -->
<!-- timestamp: 2026-03-22T20:11:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 7yns47kn -->
<!-- timestamp: 2026-03-22T20:11:40Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — 4 RED tests confirmed in test-review-workflow-classifier-dispatch.sh (opus arch reviewer section). REVIEW-WORKFLOW.md Step 4 Deep Tier section ends at line 246 with a note about the arch reviewer consuming temp files.

<!-- note-id: 90jvozfn -->
<!-- timestamp: 2026-03-22T20:11:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required — RED tests already written by dso-spfe in tests/hooks/test-review-workflow-classifier-dispatch.sh) ✓

<!-- note-id: 18s73phm -->
<!-- timestamp: 2026-03-22T20:49:01Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — Added opus arch reviewer dispatch section to REVIEW-WORKFLOW.md Step 4 Deep Tier, including: FINDINGS_A/B/C extraction, dso:code-reviewer-deep-arch dispatch with inline sonnet findings, single-writer invariant documentation, REVIEWER_HASH note. Updated Step 5 with deep tier REVIEWER_HASH provenance note.

<!-- note-id: j38o7or0 -->
<!-- timestamp: 2026-03-22T20:49:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — tests/run-all.sh: 55 passed, 0 failed; test-review-workflow-classifier-dispatch.sh: 18 passed (4 new GREEN from dso-spfe, 5 RED from w22-hwmo remain out-of-scope); ruff check: all passed; ruff format: 84 files already formatted. All 7 AC criteria verified.

<!-- note-id: qtx2w12n -->
<!-- timestamp: 2026-03-22T20:49:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-22T21:02:03Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/docs/workflows/REVIEW-WORKFLOW.md (modified). Tests: pass.
