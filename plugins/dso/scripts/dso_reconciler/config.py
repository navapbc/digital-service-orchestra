"""Configuration constants for dso_reconciler."""
from __future__ import annotations

EXCLUDED_FIELDS: tuple[str, ...] = ('dso_local_id', 'dso-id')

# Status mapping: local-side status name -> Jira-side status name.
# Used by outbound_update v1's status-routing path (gated behind
# DSO_RECONCILER_STATUS_GATING). An empty dict is a valid kill-switch
# configuration — preflight tolerates an empty mapping when no update
# mutations contain a status field.
local_to_jira_status: dict[str, str] = {
    "open": "To Do",
    "in_progress": "In Progress",
    "blocked": "Blocked",
    "closed": "Done",
    "cancelled": "Cancelled",
}
