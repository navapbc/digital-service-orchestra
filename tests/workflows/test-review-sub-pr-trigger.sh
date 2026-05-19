#!/usr/bin/env bash
# tests/workflows/test-review-sub-pr-trigger.sh
# RED-phase behavioral tests for .github/workflows/review-sub-pr.yml
#
# Story a41d-b603-95f1-4b62 (DD1): review-sub-pr.yml exists and triggers on
# PRs whose BASE branch matches session/**, session-**, session_**, bug-batch/**
#
# All tests FAIL RED because review-sub-pr.yml does not exist yet.
#
# Usage: bash tests/workflows/test-review-sub-pr-trigger.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/review-sub-pr.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-sub-pr-trigger.sh ==="

# ── test_review_sub_pr_trigger ────────────────────────────────────────────────
# The workflow file must exist and be schema-valid (actionlint exits 0).
# RED: file does not exist yet → actionlint will exit non-zero.
_snapshot_fail
actionlint_exit=1
if [ -f "$WORKFLOW_FILE" ]; then
    actionlint "$WORKFLOW_FILE" >/dev/null 2>&1 && actionlint_exit=0 || actionlint_exit=$?
fi
assert_eq "test_review_sub_pr_trigger: review-sub-pr.yml exists and passes actionlint schema validation" "0" "$actionlint_exit"
assert_pass_if_clean "test_review_sub_pr_trigger"

# ── test_triggers_on_session_slash ────────────────────────────────────────────
# on.pull_request.branches must include the 'session/**' pattern.
# RED: file does not exist → python yaml extraction yields no branches.
_snapshot_fail
has_session_slash=0
if [ -f "$WORKFLOW_FILE" ]; then
    has_session_slash=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
try:
    branches = data['on']['pull_request']['branches']
    print(1 if 'session/**' in branches else 0)
except (KeyError, TypeError):
    print(0)
PYEOF
    )
fi
assert_eq "test_triggers_on_session_slash: on.pull_request.branches includes 'session/**'" "1" "$has_session_slash"
assert_pass_if_clean "test_triggers_on_session_slash"

# ── test_triggers_on_session_dash ─────────────────────────────────────────────
# on.pull_request.branches must include the 'session-**' pattern.
# RED: file does not exist → python yaml extraction yields no branches.
_snapshot_fail
has_session_dash=0
if [ -f "$WORKFLOW_FILE" ]; then
    has_session_dash=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
try:
    branches = data['on']['pull_request']['branches']
    print(1 if 'session-**' in branches else 0)
except (KeyError, TypeError):
    print(0)
PYEOF
    )
fi
assert_eq "test_triggers_on_session_dash: on.pull_request.branches includes 'session-**'" "1" "$has_session_dash"
assert_pass_if_clean "test_triggers_on_session_dash"

# ── test_triggers_on_session_underscore ───────────────────────────────────────
# on.pull_request.branches must include the 'session_**' pattern.
# RED: file does not exist → python yaml extraction yields no branches.
_snapshot_fail
has_session_underscore=0
if [ -f "$WORKFLOW_FILE" ]; then
    has_session_underscore=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
try:
    branches = data['on']['pull_request']['branches']
    print(1 if 'session_**' in branches else 0)
except (KeyError, TypeError):
    print(0)
PYEOF
    )
fi
assert_eq "test_triggers_on_session_underscore: on.pull_request.branches includes 'session_**'" "1" "$has_session_underscore"
assert_pass_if_clean "test_triggers_on_session_underscore"

# ── test_triggers_on_bug_batch ────────────────────────────────────────────────
# on.pull_request.branches must include the 'bug-batch/**' pattern.
# RED: file does not exist → python yaml extraction yields no branches.
_snapshot_fail
has_bug_batch=0
if [ -f "$WORKFLOW_FILE" ]; then
    has_bug_batch=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
try:
    branches = data['on']['pull_request']['branches']
    print(1 if 'bug-batch/**' in branches else 0)
except (KeyError, TypeError):
    print(0)
PYEOF
    )
fi
assert_eq "test_triggers_on_bug_batch: on.pull_request.branches includes 'bug-batch/**'" "1" "$has_bug_batch"
assert_pass_if_clean "test_triggers_on_bug_batch"

# ── test_invokes_ci_llm_review_runner ─────────────────────────────────────────
# The workflow job must invoke ci-llm-review-runner.sh so sub-PR review reuses
# the same LLM dispatch path as the integration review.
# RED: file does not exist → grep finds nothing.
_snapshot_fail
invokes_runner=0
if [ -f "$WORKFLOW_FILE" ]; then
    grep -q "ci-llm-review-runner.sh" "$WORKFLOW_FILE" 2>/dev/null && invokes_runner=1 || true
fi
assert_eq "test_invokes_ci_llm_review_runner: workflow job references ci-llm-review-runner.sh" "1" "$invokes_runner"
assert_pass_if_clean "test_invokes_ci_llm_review_runner"

print_summary
