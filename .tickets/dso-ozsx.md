---
id: dso-ozsx
status: in_progress
deps: [dso-o24g, dso-ilc1]
links: []
created: 2026-03-20T00:42:24Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-6576
---
# IMPL: Update merge-to-main.sh to read ci.workflow_name with backward-compat fallback

Update merge-to-main.sh to resolve CI_WORKFLOW_NAME from ci.workflow_name first (already populated by --batch eval since ci.workflow_name uppercased = CI_WORKFLOW_NAME), then fall back to merge.ci_workflow_name (MERGE_CI_WORKFLOW_NAME) with a deprecation warning to stderr.

TDD REQUIREMENT: This task depends on dso-o24g (RED tests). All three tests in test-merge-to-main-ci-workflow-name.sh must be FAILING before starting.

CURRENT CODE (plugins/dso/scripts/merge-to-main.sh ~line 626):
  CI_WORKFLOW_NAME="${MERGE_CI_WORKFLOW_NAME:-}"

NEW CODE:
  # ci.workflow_name (preferred) → merge.ci_workflow_name (deprecated fallback)
  if [ -n "${CI_WORKFLOW_NAME:-}" ]; then
    : # already set from ci.workflow_name via --batch eval
  elif [ -n "${MERGE_CI_WORKFLOW_NAME:-}" ]; then
    CI_WORKFLOW_NAME="${MERGE_CI_WORKFLOW_NAME:-}"
    echo 'DEPRECATION WARNING: merge.ci_workflow_name is deprecated — migrate to ci.workflow_name in workflow-config.conf' >&2
  fi

IMPORTANT: The --batch eval already uppercases ci.workflow_name → CI_WORKFLOW_NAME, so CI_WORKFLOW_NAME will be populated from ci.workflow_name automatically. The old line 'CI_WORKFLOW_NAME="${MERGE_CI_WORKFLOW_NAME:-}"' overwrites this — replace it with the fallback logic above.

IMPLEMENTATION STEPS:
1. Replace the CI_WORKFLOW_NAME assignment at plugins/dso/scripts/merge-to-main.sh ~line 626
2. Run: bash tests/scripts/test-merge-to-main-ci-workflow-name.sh
3. Confirm all three tests now PASS (GREEN)
4. Also run: bash tests/scripts/test-merge-to-main-config-driven.sh (must still pass)

FILE: plugins/dso/scripts/merge-to-main.sh (edit — replace CI_WORKFLOW_NAME assignment)


## ACCEPTANCE CRITERIA

- [ ] merge-to-main.sh no longer has bare `CI_WORKFLOW_NAME="${MERGE_CI_WORKFLOW_NAME:-}"` as only assignment
  Verify: grep -c 'CI_WORKFLOW_NAME=.*MERGE_CI_WORKFLOW_NAME' $(git rev-parse --show-toplevel)/plugins/dso/scripts/merge-to-main.sh | awk '{exit ($1 == 1)}'
- [ ] merge-to-main.sh contains DEPRECATION WARNING for merge.ci_workflow_name fallback
  Verify: grep -q 'DEPRECATION WARNING.*merge.ci_workflow_name' $(git rev-parse --show-toplevel)/plugins/dso/scripts/merge-to-main.sh
- [ ] All three tests in test-merge-to-main-ci-workflow-name.sh pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-merge-to-main-ci-workflow-name.sh 2>&1 | grep -c 'FAIL' | awk '{exit ($1 > 0)}'
- [ ] Existing test-merge-to-main-config-driven.sh still passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-merge-to-main-config-driven.sh 2>&1 | grep -c 'FAIL' | awk '{exit ($1 > 0)}'
- [ ] bash -n syntax check passes on merge-to-main.sh
  Verify: bash -n $(git rev-parse --show-toplevel)/plugins/dso/scripts/merge-to-main.sh
- [ ] Deprecation warning NOT emitted when ci.workflow_name is present (only fires on merge.ci_workflow_name fallback)
  Verify: grep -A10 'DEPRECATION WARNING' $(git rev-parse --show-toplevel)/plugins/dso/scripts/merge-to-main.sh | grep -q 'MERGE_CI_WORKFLOW_NAME\|elif'

## Notes

**2026-03-20T01:42:02Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T01:42:08Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T01:42:15Z**

CHECKPOINT 3/6: Tests written (pre-existing RED) ✓

**2026-03-20T01:42:22Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T01:45:50Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T01:45:50Z**

CHECKPOINT 6/6: Done ✓
