#!/usr/bin/env bash
# check-obligations.sh — Audit open rollout obligation tickets and file
# overdue bugs.
#
# Iterates every open ticket tagged `obligation:rollout`. For each whose
# `Deadline: YYYY-MM-DD` (parsed from description) is in the past, files a
# P1 bug parented to the obligation's own parent story with body
# "OBLIGATION OVERDUE: <obligation-id>, validation command: <cmd>, days overdue: <N>".
#
# This is an AUDIT tool — it always exits 0 (even on parse errors or
# ticket-CLI failures) so it can be safely scheduled as a periodic monitor.
#
# Usage:
#   bash "${_PLUGIN_GIT_PATH}/scripts/dso_reconciler/check-obligations.sh"
#
# Environment:
#   DSO_TICKET_CLI   — override the ticket CLI path (default: .claude/scripts/dso)
#   DSO_TODAY        — override "today" (YYYY-MM-DD) for deterministic testing
#
# Contract: see docs/contracts/obligation-ticket-schema.md within the plugin tree.

set -uo pipefail

TICKET_CLI="${DSO_TICKET_CLI:-$(git rev-parse --show-toplevel 2>/dev/null)/.claude/scripts/dso}"
TODAY="${DSO_TODAY:-$(date -u +%Y-%m-%d)}"

if [[ ! -x "$TICKET_CLI" ]]; then
    echo "check-obligations: ticket CLI not found at $TICKET_CLI" >&2
    exit 0
fi

# Convert YYYY-MM-DD to epoch days (portable across macOS/Linux).
_epoch_days() {
    local d="$1"
    python3 -c "
import datetime, sys
y,m,d = '$d'.split('-')
print((datetime.date(int(y),int(m),int(d)) - datetime.date(1970,1,1)).days)
" 2>/dev/null
}

TODAY_DAYS=$(_epoch_days "$TODAY")
if [[ -z "$TODAY_DAYS" ]]; then
    echo "check-obligations: could not parse DSO_TODAY=$TODAY" >&2
    exit 0
fi

# List open obligations
LIST_JSON=$("$TICKET_CLI" ticket list --has-tag=obligation:rollout --status=open --format=llm 2>/dev/null) || {
    echo "check-obligations: ticket list failed" >&2
    exit 0
}

# Iterate ids
IDS=$(printf '%s' "$LIST_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = data if isinstance(data, list) else data.get('tickets', data.get('items', []))
for t in items:
    tid = t.get('ticket_id') or t.get('id')
    if tid:
        print(tid)
" 2>/dev/null)

OVERDUE_FILED=0
for obligation_id in $IDS; do
    SHOW_JSON=$("$TICKET_CLI" ticket show "$obligation_id" 2>/dev/null) || continue
    parsed=$(printf '%s' "$SHOW_JSON" | python3 -c "
import json, re, sys
try:
    t = json.load(sys.stdin)
except Exception:
    sys.exit(0)
desc = t.get('description','') or ''
parent = t.get('parent_id','') or ''
m_dl = re.search(r'Deadline:\s*(\d{4}-\d{2}-\d{2})', desc)
m_cmd = re.search(r'Validation command:\s*(.+)', desc)
deadline = m_dl.group(1) if m_dl else ''
cmd = m_cmd.group(1).strip() if m_cmd else ''
print(deadline)
print(parent)
print(cmd)
" 2>/dev/null)
    deadline=$(printf '%s' "$parsed" | sed -n '1p')
    parent_story=$(printf '%s' "$parsed" | sed -n '2p')
    val_cmd=$(printf '%s' "$parsed" | sed -n '3p')

    [[ -z "$deadline" ]] && continue
    deadline_days=$(_epoch_days "$deadline")
    [[ -z "$deadline_days" ]] && continue

    if (( deadline_days < TODAY_DAYS )); then
        days_overdue=$(( TODAY_DAYS - deadline_days ))
        body="OBLIGATION OVERDUE: $obligation_id, validation command: ${val_cmd:-<unspecified>}, days overdue: $days_overdue"
        title="Overdue obligation: $obligation_id (${days_overdue}d past deadline)"
        create_args=(ticket create bug "$title" --description "$body" --priority 1)
        if [[ -n "$parent_story" ]]; then
            create_args+=(--parent "$parent_story")
        fi
        "$TICKET_CLI" "${create_args[@]}" >/dev/null 2>&1 && OVERDUE_FILED=$((OVERDUE_FILED+1))
    fi
done

echo "check-obligations: filed $OVERDUE_FILED overdue bug(s) (today=$TODAY)" >&2
exit 0
