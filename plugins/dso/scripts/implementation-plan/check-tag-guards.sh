#!/usr/bin/env bash
set -euo pipefail
# check-tag-guards.sh
# Pre-flight tag guard for /dso:implementation-plan.
#
# Checks a ticket for blocking tags that should halt planning:
#   - scrutiny:pending          — epic has not been through scrutiny review
#   - interaction:deferred      — unresolved cross-epic interaction conflicts
#   - manual:awaiting_user      — manual story (only blocking when
#                                 planning.external_dependency_block_enabled=true)
#
# Usage:
#   check-tag-guards.sh <ticket-id>
#
# Output (one line on stdout):
#   OK
#   BLOCKED:scrutiny_pending
#   BLOCKED:interaction_deferred
#   BLOCKED:manual_awaiting_user
#
# Exit codes:
#   0 — OK (no blocking tag)
#   1 — BLOCKED (one of the tags is set)
#   2 — Lookup failure (fail-open in caller — treat as OK)
#
# The caller is responsible for emitting the user-facing message and any
# STATUS line. This script only reports verdict + tag.

TICKET_ID="${1:-}"
[[ -z "$TICKET_ID" ]] && { echo "usage: check-tag-guards.sh <ticket-id>" >&2; exit 2; }

_show=$(.claude/scripts/dso ticket show "$TICKET_ID" 2>/dev/null) || { echo "OK"; exit 2; }

# `set -e` is locally suspended for the helper because callers branch on the
# 0|1|2 verdict — we MUST observe the exit code, not abort on non-zero.
_has_tag() {
    set +e
    echo "$_show" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    tags = d.get('tags') or []
    sys.exit(0 if '$1' in tags else 1)
except Exception:
    sys.exit(2)
"
    local _rc=$?
    set -e
    return $_rc
}

if _has_tag "scrutiny:pending"; then
    echo "BLOCKED:scrutiny_pending"
    exit 1
fi

if _has_tag "interaction:deferred"; then
    echo "BLOCKED:interaction_deferred"
    exit 1
fi

# manual:awaiting_user is gated by the planning.external_dependency_block_enabled config
_ext_enabled=$(.claude/scripts/dso read-config planning.external_dependency_block_enabled 2>/dev/null || echo "")
if [[ "$_ext_enabled" == "true" ]]; then
    if _has_tag "manual:awaiting_user"; then
        echo "BLOCKED:manual_awaiting_user"
        exit 1
    fi
fi

echo "OK"
exit 0
