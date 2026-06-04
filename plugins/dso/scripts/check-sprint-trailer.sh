#!/usr/bin/env bash
# check-sprint-trailer.sh: Pre-commit hook enforcing DSO-Story trailers in sprint mode.
# Enforcement uses a 4-cell matrix gated on BOTH conditions:
#   - dso.workflow=ci-pr  (read via read-config.sh / WORKFLOW_CONFIG_FILE)
#   - .sprint-active file present at repo root
# Enforcement occurs ONLY when both conditions are true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"

_wf=$(bash "$SCRIPT_DIR/read-config.sh" dso.workflow 2>/dev/null || echo "local")
_sprint_active=0
[[ -f "$REPO_ROOT/.sprint-active" ]] && _sprint_active=1
# OR-alternative: DSO_SPRINT_TRAILER_REQUIRED=1 triggers enforcement in agent
# sub-branch worktrees where .sprint-active must NOT be present (bug 3349-8532).
# This widens WHEN enforcement triggers but does not weaken any existing cell.
[[ "${DSO_SPRINT_TRAILER_REQUIRED:-}" == "1" ]] && _sprint_active=1

# 4-cell matrix: enforce ONLY when dso.workflow=ci-pr AND (.sprint-active exists
# OR DSO_SPRINT_TRAILER_REQUIRED=1). All existing cells remain intact.
if [[ "$_wf" != "ci-pr" || "$_sprint_active" -eq 0 ]]; then
    exit 0
fi

# Read the message of the commit BEING MADE, not the previous HEAD commit
# (bug aba6-56fa). Resolution order:
#   1. $1 if it points to a readable file — explicit caller override. Used
#      by the test harness for direct invocation. NOTE: in the current
#      pre-commit-wrapper.sh dispatch shape, $1 is consumed by the wrapper
#      and not forwarded to the inner script, so this branch is dead under
#      pre-commit framework invocation in production — but production
#      reaches branch 2 below. Retained as the explicit-caller override
#      and forward-compatible with a future wrapper that does forward $1
#      (PR #180 review finding).
#   2. $GIT_DIR/COMMIT_EDITMSG — git writes the in-progress message here
#      before firing commit-msg hooks; this is the actual production path
#      under pre-commit-wrapper.sh + stages: [commit-msg] registration.
#   3. git log -1 — last-resort for ad-hoc direct invocation outside a
#      commit flow (manual debugging). Reflects previous-commit semantics;
#      the stages: [commit-msg] registration ensures it is not reached in
#      production.
_msg_file=""
if [[ -n "${1:-}" && -f "$1" ]]; then
    _msg_file="$1"
elif _git_dir=$(git rev-parse --git-dir 2>/dev/null) && [[ -f "$_git_dir/COMMIT_EDITMSG" ]]; then
    _msg_file="$_git_dir/COMMIT_EDITMSG"
fi
if [[ -n "$_msg_file" ]]; then
    _commit_msg=$(cat "$_msg_file" 2>/dev/null || echo "")
else
    _commit_msg=$(git log -1 --format=%B 2>/dev/null || echo "")
fi
_has_trailer=0
if echo "$_commit_msg" | git interpret-trailers --parse 2>/dev/null | grep -q '^DSO-Story:'; then
    _has_trailer=1
fi

if [[ "$_has_trailer" -eq 0 ]]; then
    echo "ERROR: check-sprint-trailer: DSO-Story trailer required in sprint mode but not found in commit message. Run /dso:commit from within the story worktree to inject the trailer automatically." >&2
    exit 1
fi

exit 0
