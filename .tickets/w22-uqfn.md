---
id: w22-uqfn
status: open
deps: []
links: []
created: 2026-03-20T14:53:18Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-ppwp
---
# As a developer, tests associated with my changed files must pass before I can commit

## Description

**What**: Core test gate enforcement — convention-based test association, test status recording, pre-commit hook verification, and commit workflow integration.
**Why**: This is the walking skeleton that proves the concept end-to-end. Without it, test regressions enter the codebase silently.
**Scope**:
- IN: Convention-based association lookup (foo.py → test_foo.py search in test directory tree), record-test-status.sh (discovers associated tests, runs them, records hash via compute-diff-hash.sh), pre-commit-test-gate.sh (verifies test-status file exists, hash matches staged diff, status is "passed"), exit 144 → actionable failure message with test-batched.sh guidance, registration in .pre-commit-config.yaml alongside review gate, COMMIT-WORKFLOW.md integration (record-test-status.sh invocation step)
- OUT: Bypass prevention (w22-sulb), slow test exemption (w22-8jaf)

## Done Definitions

- When this story is complete, a commit touching foo.py is blocked unless test_foo.py passes and the test-status hash is recorded matching the staged diff
  ← Satisfies: "A git commit is blocked when the test-status file is absent, its recorded diff hash does not match the current staged diff, or its status is not 'passed'"
- When this story is complete, a commit touching foo.py where test_foo.py exits 144 displays an error message containing the test-batched.sh command and resume instructions
  ← Satisfies: "When the test runner is terminated (exit 144), the failure message provides actionable guidance"
- When this story is complete, a commit touching only __init__.py or files with no associated test succeeds without test gate intervention
  ← Satisfies: "files with no associated test pass the gate without blocking"
- When this story is complete, the test gate and review gate coexist — a test-gate-only failure blocks with a test-gate-specific error and leaves review-status unchanged
  ← Satisfies: "When only the test gate is unsatisfied, the commit is blocked with a test-gate-specific error and the review-status file is unmodified"
- When this story is complete, COMMIT-WORKFLOW.md includes a step to invoke record-test-status.sh at the correct point in the workflow (after formatting and staging, before the commit)
  ← Satisfies: "The gate integrates into the existing commit workflow sequence"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Reliability] Hash computation shared with review gate via compute-diff-hash.sh — reuse, do not fork
- [Maintainability] Reuse shared utilities from deps.sh (get_artifacts_dir, hash_stdin, parse_json_field)
- [Reliability] Convention-based association may miss non-standard naming — document limitations and exempt-file behavior
- [Testing] Synthetic git operations in tests must use isolated temp repos to avoid polluting the real repository
- [Reliability] .pre-commit-config.yaml has fail_fast: true — hook ordering determines which gate error the developer sees first; design the ordering so the test gate error is actionable regardless of review gate state
- [Reliability] compute-diff-hash.sh computes working-tree diff (not git diff --cached) — record-test-status.sh must capture the hash at a point in the commit workflow where it will match at verification time (i.e., after staging, same as record-review.sh)

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

## Notes

**2026-03-20T19:05:01Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
