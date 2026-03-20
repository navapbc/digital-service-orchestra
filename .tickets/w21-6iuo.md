---
id: w21-6iuo
status: open
deps: [w21-l7zk]
links: []
created: 2026-03-20T19:10:55Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-uqfn
---
# IMPL: Add record-test-status.sh invocation step to COMMIT-WORKFLOW.md

Add a new Step 3.5 to plugins/dso/docs/workflows/COMMIT-WORKFLOW.md that instructs the agent to invoke record-test-status.sh at the correct point in the workflow.

Placement: AFTER Step 3b (Version Bump) and BEFORE Step 4 (Stage), OR between Step 3a (Write Validation State File) and Step 3b (Version Bump). The Consideration says: 'after formatting and staging, before the commit' and 'after staging, same as record-review.sh'. 

Correct placement: AFTER Step 4 (Stage) and BEFORE Step 5 (Review Gate). This ensures:
- The hash is computed AFTER git add (same as record-review.sh requirement)
- Tests are run against the staged state that will be committed
- This matches the story done definition: 'after formatting and staging, before the commit'

Wait — re-read the Consideration: 'record-test-status.sh must capture the hash at a point in the commit workflow where it will match at verification time (i.e., after staging, same as record-review.sh)'. record-review.sh calls compute-diff-hash.sh which uses git diff (unstaged+staged), not git diff --cached. The hash is staging-invariant. But the gate checks compute-diff-hash.sh too. So the hash must match between record time and gate time — both use compute-diff-hash.sh which is staging-invariant.

Placement decision: Step 3.5 (after Step 3 lint/type-check, before Step 3a validation state) — so tests run AFTER formatting/linting, but BEFORE staging. This lets record-test-status.sh discover which source files are about to be staged via git diff --name-only, then run associated tests, record the hash.

New Step 3.5 should include:
- Brief explanation: 'Run record-test-status.sh to discover and run tests for files about to be staged. This records the test-gate-status file that the pre-commit test gate will verify at commit time.'
- Command block:
  bash '$(git rev-parse --show-toplevel)/plugins/dso/hooks/record-test-status.sh'
- Exit code guidance:
  - exit 0: all associated tests passed (or no associated tests found) — continue
  - exit 144: test runner was terminated; follow the actionable guidance printed by record-test-status.sh
  - exit non-zero (other): tests failed; fix the failures and restart from Step 1
- Breadcrumb line:
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-3.5-record-test-status" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"

The step must be clearly labeled as Step 3.5 and placed between the existing Step 3 and Step 3a sections.

## Acceptance Criteria

- [ ] COMMIT-WORKFLOW.md contains '## Step 3.5' or 'Step 3.5'
  Verify: grep -q 'Step 3.5\|## Step 3\.5' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md
- [ ] COMMIT-WORKFLOW.md references record-test-status.sh in the new step
  Verify: grep -q 'record-test-status.sh' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md
- [ ] Step 3.5 includes actionable guidance for exit 144 (test-batched.sh)
  Verify: grep -A15 'Step 3.5\|step-3.5' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md | grep -q 'test-batched\|exit 144'
- [ ] Step 3.5 is placed AFTER Step 3 and BEFORE Step 3a
  Verify: python3 -c "import re; c=open('$(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md').read(); s3=c.find('## Step 3:'); s35=c.find('3.5'); s3a=c.find('## Step 3a:'); exit(0 if s3 < s35 < s3a else 1)"
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

