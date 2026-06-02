#!/usr/bin/env bash
# check-antipattern-scan-trailer.sh: Pre-commit hook enforcing Antipattern-Scan trailers
# in fix-bug sessions.
# Enforcement is gated on the presence of .fix-bug-active at repo root — the hook
# is a no-op (exit 0) outside a fix-bug session, so it never blocks sprint,
# docs, or other skill commits.
#
# When active, this hook enforces:
#   1. An Antipattern-Scan trailer MUST be present in the commit message.
#   2. When matches > 0, each match must be accounted for by one of:
#        a. An Antipattern-Ticket: <id> trailer in the commit message, OR
#        b. A match/findings file staged in the cached diff (git diff --cached), OR
#        c. A '# antipattern-ok: <reason>' annotation in the commit message,
#           where <reason> ∈ {different-context, dead-code, already-tracked:<id>}.
#              — Capped at 3 antipattern-ok annotations per session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"

# ---------------------------------------------------------------------------
# Gate: only enforce during fix-bug sessions (.fix-bug-active marker)
# ---------------------------------------------------------------------------
if [[ ! -f "$REPO_ROOT/.fix-bug-active" ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Resolve commit message. Resolution order (mirrors check-sprint-trailer.sh):
#   1. $1 if it points to a readable file — explicit caller override. Used
#      by the test harness for direct invocation.
#   2. $GIT_DIR/COMMIT_EDITMSG — git writes the in-progress message here
#      before firing commit-msg hooks; this is the actual production path.
#   3. git log -1 — last-resort for ad-hoc direct invocation outside a
#      commit flow (manual debugging, reflects previous-commit semantics).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Rule 1: Antipattern-Scan trailer must be present.
# Trailer grammar: Antipattern-Scan: <query> root=<scan-root> matches=<n>
# ---------------------------------------------------------------------------
_scan_line=""
_scan_line=$(printf '%s\n' "$_commit_msg" | grep -E '^Antipattern-Scan:' | head -1 || true)

if [[ -z "$_scan_line" ]]; then
    echo "ERROR: check-antipattern-scan-trailer: Antipattern-Scan trailer required in fix-bug mode but not found in commit message. Add a trailer of the form: Antipattern-Scan: <query> root=<root> matches=<n>" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract matches count from the trailer line.
# ---------------------------------------------------------------------------
_matches=0
if [[ "$_scan_line" =~ matches=([0-9]+) ]]; then
    _matches="${BASH_REMATCH[1]}"
fi

# matches=0: no follow-up artifact required.
if [[ "$_matches" -eq 0 ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Rule 2: matches > 0 — check for follow-up artifact.
# Priority: ticket id in trailer → cached diff file → antipattern-ok annotations.
# ---------------------------------------------------------------------------

# Check 2a: Antipattern-Ticket: <id> trailer present.
_has_ticket=0
if printf '%s\n' "$_commit_msg" | grep -qE '^Antipattern-Ticket:'; then
    _has_ticket=1
fi
if [[ "$_has_ticket" -eq 1 ]]; then
    exit 0
fi

# Check 2b: A match/findings file is staged in the cached diff.
_has_diff_file=0
_staged_files=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -n "$_staged_files" ]]; then
    _has_diff_file=1
fi
if [[ "$_has_diff_file" -eq 1 ]]; then
    exit 0
fi

# Check 2c: antipattern-ok annotations in the commit message.
# Annotation format: # antipattern-ok: <reason>
# Valid reasons: different-context, dead-code, already-tracked:<id>
# Cap: no more than 3 annotations per session.

_ANTIPATTERN_OK_CAP=3

# Collect all antipattern-ok annotation lines.
_ok_lines=()
while IFS= read -r line; do
    if [[ "$line" =~ ^#[[:space:]]*antipattern-ok:[[:space:]]*(.*) ]]; then
        _ok_lines+=("${BASH_REMATCH[1]}")
    fi
done <<< "$_commit_msg"

_ok_count="${#_ok_lines[@]}"

# Enforce cap: more than 3 annotations is always a rejection.
if [[ "$_ok_count" -gt "$_ANTIPATTERN_OK_CAP" ]]; then
    echo "ERROR: check-antipattern-scan-trailer: antipattern-ok annotation cap of ${_ANTIPATTERN_OK_CAP}/session exceeded (found ${_ok_count}). Use a ticket id (Antipattern-Ticket:) or stage a match file instead." >&2
    exit 1
fi

if [[ "$_ok_count" -gt 0 ]]; then
    # Validate each annotation reason.
    for _reason in "${_ok_lines[@]}"; do
        case "$_reason" in
            different-context|dead-code)
                # Valid short-form reasons.
                ;;
            already-tracked:*)
                # Valid: already-tracked:<id> — the id suffix may be any non-empty string.
                _tracked_id="${_reason#already-tracked:}"
                if [[ -z "$_tracked_id" ]]; then
                    echo "ERROR: check-antipattern-scan-trailer: invalid antipattern-ok reason '${_reason}' — already-tracked requires a non-empty ticket id (e.g., already-tracked:abcd-1234). Valid reasons: {different-context, dead-code, already-tracked:<id>}." >&2
                    exit 1
                fi
                ;;
            *)
                echo "ERROR: check-antipattern-scan-trailer: invalid antipattern-ok reason '${_reason}'. Valid reasons: {different-context, dead-code, already-tracked:<id>}." >&2
                exit 1
                ;;
        esac
    done
    # All annotations are valid and within cap — follow-up satisfied.
    exit 0
fi

# No follow-up artifact found.
echo "ERROR: check-antipattern-scan-trailer: Antipattern-Scan trailer reports matches=${_matches} but no per-match follow-up artifact found. Provide one of: (a) Antipattern-Ticket: <id> trailer, (b) a staged match-file in the cached diff, or (c) '# antipattern-ok: <reason>' annotation(s) where reason ∈ {different-context, dead-code, already-tracked:<id>} (cap: ${_ANTIPATTERN_OK_CAP}/session)." >&2
exit 1
