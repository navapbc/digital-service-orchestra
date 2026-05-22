#!/usr/bin/env bash
set -euo pipefail
# check-reinvocation.sh
# Re-invocation guard for /dso:implementation-plan.
#
# Classifies the children of a story/epic by status to decide whether this
# is a fresh planning, a no-op (all already closed), a hold (in-progress
# children), or a diff plan (mixed open/closed children).
#
# Usage:
#   check-reinvocation.sh <story-or-epic-id>
#
# Output (KEY=VALUE lines on stdout):
#   verdict=fresh|all_closed|in_progress_hold|diff_plan|replan_required
#   closed_count=<int>
#   in_progress_count=<int>
#   open_count=<int>
#   closed_ids=<comma-separated>
#   in_progress_ids=<comma-separated>
#   open_ids=<comma-separated>
#
# Exit codes:
#   0 — verdict produced
#   2 — Lookup failure (caller treats as fresh, fail-open)
#
# The caller is responsible for emitting the STATUS line based on verdict
# (e.g., STATUS:complete TASKS:... STORY:... when verdict=all_closed).
#
# replan_required (bug 95db-941d-04d8-41d1): emitted when all child tasks are
# closed BUT the parent epic has an unresolved REPLAN_TRIGGER:validation
# comment mentioning this story — i.e., the completion-verifier flagged a
# story-level FAIL after the original tasks closed and no
# REPLAN_RESOLVED:implementation-plan has acknowledged it yet. The caller
# (implementation-plan SKILL.md) must enter diff-plan mode and create new
# TDD remediation tasks; emitting STATUS:complete here causes the
# verifier ↔ impl-plan loop the bug describes.

TICKET_ID="${1:-}"
[[ -z "$TICKET_ID" ]] && { echo "usage: check-reinvocation.sh <ticket-id>" >&2; exit 2; }

_deps=$(.claude/scripts/dso ticket deps "$TICKET_ID" --include-archived 2>/dev/null) || { echo "verdict=fresh"; exit 2; }

_children=$(echo "$_deps" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(','.join(d.get('children') or []))
except Exception:
    pass
" 2>/dev/null)

if [[ -z "$_children" ]]; then
    echo "verdict=fresh"
    echo "closed_count=0"
    echo "in_progress_count=0"
    echo "open_count=0"
    echo "closed_ids="
    echo "in_progress_ids="
    echo "open_ids="
    exit 0
fi

closed_ids=()
in_progress_ids=()
open_ids=()

IFS=',' read -ra _child_arr <<< "$_children"
for cid in "${_child_arr[@]}"; do
    [[ -z "$cid" ]] && continue
    # `|| continue` requires `set +e` because pipefail-aware `set -e` aborts
    # on the substitution failure before the `||` clause runs.
    set +e
    _info=$(.claude/scripts/dso ticket show "$cid" 2>/dev/null)
    _show_rc=$?
    set -e
    [[ $_show_rc -ne 0 ]] && continue
    _classification=$(echo "$_info" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    if d.get('archived') is True or d.get('status') == 'closed':
        print('closed')
    elif d.get('status') == 'in_progress':
        print('in_progress')
    else:
        print('open')
except Exception:
    print('open')
")
    case "$_classification" in
        closed)      closed_ids+=("$cid") ;;
        in_progress) in_progress_ids+=("$cid") ;;
        *)           open_ids+=("$cid") ;;
    esac
done

_join() { local IFS=','; echo "$*"; }

closed_count=${#closed_ids[@]}
in_progress_count=${#in_progress_ids[@]}
open_count=${#open_ids[@]}

# Edge case: children list was non-empty but every ticket-show call failed.
# Treat as fresh+error (fail-open), consistent with the lookup-failure path
# at the top of this script. Otherwise the verdict would fall through to
# diff_plan with empty open_ids — an incoherent contract for the caller.
_total_classified=$(( closed_count + in_progress_count + open_count ))
if (( _total_classified == 0 )); then
    echo "verdict=fresh"
    echo "closed_count=0"
    echo "in_progress_count=0"
    echo "open_count=0"
    echo "closed_ids="
    echo "in_progress_ids="
    echo "open_ids="
    exit 2
fi

if (( in_progress_count > 0 )); then
    verdict="in_progress_hold"
elif (( open_count == 0 && closed_count > 0 )); then
    verdict="all_closed"
else
    verdict="diff_plan"
fi

# REPLAN_TRIGGER:validation override (bug 95db-941d-04d8-41d1).
# When the initial verdict is "all_closed" we still must check whether the
# completion-verifier flagged a story-level FAIL after the original tasks
# closed. The verifier emits a REPLAN_TRIGGER:validation comment mentioning
# the story id onto the parent epic; impl-plan acknowledges that with a
# REPLAN_RESOLVED:implementation-plan comment (also mentioning the story id)
# after creating remediation tasks. An unresolved trigger means new
# remediation tasks have not yet been created — return replan_required so
# the caller routes to diff-plan mode instead of emitting STATUS:complete.
if [[ "$verdict" == "all_closed" ]]; then
    set +e
    _self_info=$(.claude/scripts/dso ticket show "$TICKET_ID" 2>/dev/null)
    _self_rc=$?
    set -e
    if [[ $_self_rc -eq 0 ]]; then
        _parent_id=$(echo "$_self_info" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('parent_id') or '')
except Exception:
    pass
" 2>/dev/null)
        if [[ -n "$_parent_id" ]]; then
            set +e
            _parent_info=$(.claude/scripts/dso ticket show "$_parent_id" 2>/dev/null)
            _parent_rc=$?
            set -e
            if [[ $_parent_rc -eq 0 ]]; then
                _replan_state=$(echo "$_parent_info" | python3 -c "
import json, sys
story_id = sys.argv[1]
try:
    d = json.loads(sys.stdin.read())
    comments = d.get('comments', []) or []
except Exception:
    print('error')
    sys.exit(0)

# Walk comments in order; track the latest REPLAN_TRIGGER:validation index
# that mentions this story and whether any later REPLAN_RESOLVED:implementation-plan
# referencing the same story appears after it.
latest_trigger_idx = -1
latest_resolved_after_idx = -1
for i, c in enumerate(comments):
    body = (c.get('body') or c.get('text') or '')
    if 'REPLAN_TRIGGER:' in body and 'validation' in body and story_id in body:
        latest_trigger_idx = i
        latest_resolved_after_idx = -1  # reset on a new trigger
    elif latest_trigger_idx >= 0 and 'REPLAN_RESOLVED:' in body and 'implementation-plan' in body and story_id in body:
        latest_resolved_after_idx = i

if latest_trigger_idx < 0:
    print('none')
elif latest_resolved_after_idx > latest_trigger_idx:
    print('resolved')
else:
    print('unresolved')
" "$TICKET_ID" 2>/dev/null)
                if [[ "$_replan_state" == "unresolved" ]]; then
                    verdict="replan_required"
                fi
            fi
        fi
    fi
fi

echo "verdict=$verdict"
echo "closed_count=$closed_count"
echo "in_progress_count=$in_progress_count"
echo "open_count=$open_count"
echo "closed_ids=$(_join "${closed_ids[@]:-}")"
echo "in_progress_ids=$(_join "${in_progress_ids[@]:-}")"
echo "open_ids=$(_join "${open_ids[@]:-}")"
exit 0
