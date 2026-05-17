#!/usr/bin/env bash
# assert-batch-branch.sh
# Refuses to allow debug-everything Phase F/G to open a sub-branch PR (and rely
# on per-branch-review.yml firing on push) without a properly created and
# pushed bug-batch sub-branch.
#
# Without this gate, an orchestrator error that skipped
# `git checkout -b bug-batch/...` or `git push origin <sub>` silently lands the
# changes on the session branch with no CI review — the exact failure mode that
# PR #188 (Flow A) closed for direct PRs but left open for debug-everything's
# bug-batch/** flow (Flow C).
#
# Contract:
#   - When dso.workflow != ci-pr → exit 0 silently (no-op).
#   - When dso.workflow == ci-pr:
#       * BATCH_BRANCH arg (positional 1) must be set and non-empty
#       * BATCH_BRANCH must match the bug-batch/ prefix
#       * The branch named in BATCH_BRANCH must exist locally
#       * The branch must be pushed to origin (so per-branch-review.yml can fire)
#     Any failure → exit 1 with a remediation message on stderr.
#
# Usage: assert-batch-branch.sh <branch-name>
# Example: assert-batch-branch.sh "bug-batch/2026-05-17-debug/tier-3-batch-1"
#
# Environment:
#   WORKFLOW_CONFIG_FILE — optional path to a dso-config.conf (test isolation)
#   CLAUDE_PLUGIN_ROOT   — optional path to plugin root (auto-detected if absent)
#
# Exit codes:
#   0 — local mode no-op, or ci-pr mode with batch branch present + pushed
#   1 — ci-pr mode missing/invalid BATCH_BRANCH / branch / origin tracking

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
_READ_CONFIG="$_PLUGIN_ROOT/scripts/read-config.sh"

# Read dso.workflow. If read-config.sh is missing or fails, treat as local.
# Fail-open is intentional: this is a defense-in-depth gate, not the only one.
_workflow=""
if [[ -x "$_READ_CONFIG" ]]; then
    _workflow=$(DSO_DEPRECATION_QUIET=1 bash "$_READ_CONFIG" dso.workflow 2>/dev/null || true)
fi

if [[ "$_workflow" != "ci-pr" ]]; then
    # Local mode (or no config): no-op exit 0.
    exit 0
fi

# ci-pr mode: BATCH_BRANCH must be passed as the first positional arg.
BATCH_BRANCH="${1:-}"

if [[ -z "$BATCH_BRANCH" ]]; then
    cat >&2 <<EOF
ERROR: assert-batch-branch.sh requires a branch name as the first argument.
The debug-everything orchestrator must create a bug-batch sub-branch before
opening a per-tier or per-batch PR.

Remediation (example for debug-session 2026-05-17, tier 3 batch 1):
  git checkout -b "bug-batch/2026-05-17-debug/tier-3-batch-1"
  git push -u origin "bug-batch/2026-05-17-debug/tier-3-batch-1"
  .claude/scripts/dso assert-batch-branch.sh "bug-batch/2026-05-17-debug/tier-3-batch-1"

Without a pushed bug-batch sub-branch, per-branch-review.yml will not trigger
and LLM Sub-Branch Review will be silently bypassed.
EOF
    exit 1
fi

# Verify the bug-batch/ prefix — the workflow's push.branches filter matches
# only sub-branches under this namespace.
if [[ "$BATCH_BRANCH" != bug-batch/* ]]; then
    cat >&2 <<EOF
ERROR: BATCH_BRANCH='$BATCH_BRANCH' does not match the required prefix.
debug-everything Phase F/G sub-branches MUST be named 'bug-batch/<...>' so
per-branch-review.yml's push.branches filter ('bug-batch/**') will match.

Remediation:
  Rename or recreate the branch under the bug-batch/ namespace:
    git checkout -b "bug-batch/\$DEBUG_SESSION_ID/tier-\$N[-batch-\$K]"
EOF
    exit 1
fi

# Verify the branch exists locally. Uses `git show-ref --verify` (exact ref
# match) rather than `git branch --list | grep` because:
#   - `git branch` prefixes the current branch with `* ` (e.g. `* bug-batch/...`),
#     which a naive regex check fails to match.
#   - Branch names can contain regex metacharacters (`.`, `*`, `+`) that would
#     misbehave in a `grep -E` pattern.
# `git show-ref --verify --quiet refs/heads/<name>` does an exact ref lookup
# with no regex semantics and is the canonical way to test for local branch
# existence.
if ! git show-ref --verify --quiet "refs/heads/$BATCH_BRANCH"; then
    cat >&2 <<EOF
ERROR: BATCH_BRANCH='$BATCH_BRANCH' does not exist locally.

Remediation:
  git checkout -b "$BATCH_BRANCH"

debug-everything Phase F/G must create the sub-branch directly via
'git checkout -b bug-batch/...' before applying tier changes (see the
debug-everything SKILL.md Phase F and Phase G sub-branch sections).
EOF
    exit 1
fi

# Verify the branch is pushed to origin (this is what makes per-branch-review.yml fire).
if ! git ls-remote --exit-code origin "refs/heads/$BATCH_BRANCH" >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: BATCH_BRANCH='$BATCH_BRANCH' exists locally but has NOT been pushed to origin.
per-branch-review.yml triggers on push to bug-batch/** — without the push,
LLM Sub-Branch Review will not run for this tier/batch.

Remediation:
  git push -u origin "$BATCH_BRANCH"
EOF
    exit 1
fi

# All checks pass.
exit 0
