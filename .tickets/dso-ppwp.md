---
id: dso-ppwp
status: in_progress
deps: []
links: []
created: 2026-03-17T18:34:10Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-26
---
# Add test gate enforcement

## Context
The DSO workflow enforces code review integrity via a two-layer gate (git pre-commit hook + PreToolUse hook) that blocks commits without verified review. No equivalent gate exists for tests — an agent can commit code with failing associated tests, and the only safety net is post-commit CI. This means test regressions can enter the codebase silently, accumulating pre-existing failures that compound over time. The test gate closes this gap using the same hash-verification and defense-in-depth pattern proven by the review gate, enforced on a "you touch it, you own it" basis.

Test-to-source file association uses a convention-based lookup: for each staged source file foo.py, the gate searches the test directory tree for files named test_foo.py and collects all matches as associated tests. Files with zero matches (e.g., __init__.py, migrations, config) are exempt — no test required. The hash is computed identically to the review gate’s diff hash (SHA-256 of git diff --cached). Test-status and exemption data are stored in the artifacts directory (resolved via get_artifacts_dir() from hooks/lib/deps.sh, same as the review-status file).

"Protected" means the same pattern used by record-review.sh / reviewer-findings.json: only the named scripts (record-test-status.sh, record-test-exemption.sh) may write to the test-status and exemption files. Layer 2 (PreToolUse hook) blocks any Bash tool call that writes to these files directly, following the same sentinel pattern as review-gate-bypass-sentinel.sh.

## Success Criteria
1. A git commit is blocked when the test-status file is absent, its recorded diff hash does not match the current staged diff, or its status is not "passed" — the gate exits non-zero with a structured error identifying the condition (MISSING, HASH_MISMATCH, or NOT_PASSED)
2. Bypass attempts (flag --no-verify, git plumbing commands, core.hooksPath= overrides, direct writes to the test-status or exemption files) are intercepted and blocked at the PreToolUse layer, independent of git hooks
3. When the test runner is terminated (exit 144), the failure message provides actionable guidance including the test-batched.sh command for completing tests in time-bounded loops with resume capability
4. record-test-exemption.sh accepts a single test node ID, runs it in isolation with a 60-second timeout, and writes an exemption only when the test exceeds the timeout — the exemption entry records the test node ID, timeout threshold, and timestamp; the gate treats exempted tests as passing for hash verification
5. Test-to-source file association is convention-based (foo.py → test_foo.py) and deterministic — not agent-configurable; files with no associated test pass the gate without blocking
6. When both the test gate and review gate are satisfied, git commit succeeds. When only the test gate is unsatisfied, the commit is blocked with a test-gate-specific error and the review-status file is unmodified. When only the review gate is unsatisfied, the commit is blocked with a review-gate-specific error and the test-status file is unmodified.
7. A test suite validates both layers: a synthetic commit introducing a failing test for a changed file is blocked by Layer 1; the same attempt using the no-verify flag is blocked by Layer 2

## Dependencies
- Requires the review gate’s two-layer architecture to remain stable as the template pattern (specifically: the artifacts directory convention, the diff-hash computation, and the PreToolUse dispatcher). The test gate mirrors this architecture but does not modify it.
- dso-dywv (Improved code review) is a sequencing consideration — if it changes the review gate’s hook architecture, test gate integration points may need coordination.
- The test gate is always-on with no project-level override; dso-0wi2 (Project level config flags) is out of scope.

## Approach
Mirror the review gate’s two-layer architecture. Layer 1: a git pre-commit hook verifies the test-status hash against the staged diff. Layer 2: a PreToolUse sentinel blocks bypass vectors and direct writes to protected files. record-test-status.sh runs associated tests and records the hash atomically. record-test-exemption.sh handles the slow-test escape hatch.

