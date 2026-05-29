"""Inbound differ for bidirectional Jira sync.

Detects Jira-side changes for bound tickets and emits inbound update mutations
to apply to the local ticket system. Only processes tickets that are already
bound in the BindingStore — unbound Jira issues are ignored (local is source
of truth; they will be handled by outbound creates).

Conflict resolution: local wins. When both local and Jira have changed a
field, the change is skipped (the outbound differ will push the local value).

This module is pure: no I/O, no time/random, no logging, no globals.

Dependency: BindingStore interface (PR #401). This module codes against the
interface — get_local_id(jira_key) -> str|None — and does not import the
concrete class.
"""

from __future__ import annotations

import importlib.util
import sys
from dataclasses import dataclass, field as dataclass_field
from pathlib import Path
from typing import Any, Protocol, runtime_checkable


# Reconciler loop-breaker marker (Gap 1). Outbound comments embed this
# token; inbound passes filter any Jira comment whose body contains it
# so we do not detect our own echoes as new Jira-side comments.
RECONCILER_MARKER = "<!-- dso:reconciler-echo -->"


_ADF_KEY_INBOUND = "plugins.dso.scripts.dso_reconciler.adf"
_AdfModule_Inbound = None


def _load_adf():
    """Lazy-load the sibling adf module (mirrors outbound_differ._load_adf)."""
    global _AdfModule_Inbound
    if _AdfModule_Inbound is not None:
        return _AdfModule_Inbound
    if _ADF_KEY_INBOUND in sys.modules:
        _AdfModule_Inbound = sys.modules[_ADF_KEY_INBOUND]
        return _AdfModule_Inbound
    adf_path = Path(__file__).parent / "adf.py"
    spec = importlib.util.spec_from_file_location(_ADF_KEY_INBOUND, adf_path)
    if spec is None or spec.loader is None:
        raise FileNotFoundError(f"adf.py not found at {adf_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[_ADF_KEY_INBOUND] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    _AdfModule_Inbound = mod
    return mod


# ---------------------------------------------------------------------------
# BindingStore protocol — codes against PR #401's interface
# ---------------------------------------------------------------------------


@runtime_checkable
class BindingStoreProtocol(Protocol):
    """Minimal interface for the inbound binding store lookup."""

    def get_local_id(self, jira_key: str) -> str | None: ...


# ---------------------------------------------------------------------------
# InboundMutation dataclass
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class InboundMutation:
    """A single inbound change to apply to the local ticket system."""

    jira_key: str
    local_id: str
    action: str  # "update"
    fields: dict[str, Any]  # changed fields only
    comments: list[dict[str, Any]] = dataclass_field(default_factory=list)
    labels: list[dict[str, Any]] = dataclass_field(default_factory=list)


# ---------------------------------------------------------------------------
# Field mapping constants (Jira -> local)
# ---------------------------------------------------------------------------

_JIRA_TO_LOCAL_TYPE: dict[str, str] = {
    "Bug": "bug",
    "Story": "story",
    "Task": "task",
    "Epic": "epic",
}

_JIRA_TO_LOCAL_PRIORITY: dict[str, int] = {
    "Highest": 0,
    "High": 1,
    "Medium": 2,
    "Low": 3,
    "Lowest": 4,
}

_JIRA_TO_LOCAL_STATUS: dict[str, str] = {
    "To Do": "open",
    "In Progress": "in_progress",
    "Blocked": "blocked",
    "Done": "closed",
    "Cancelled": "cancelled",
}


# ---------------------------------------------------------------------------
# Field extraction helpers
# ---------------------------------------------------------------------------


def _extract_jira_field_value(jira_fields: dict[str, Any], field: str) -> Any:
    """Extract a Jira field value, handling nested structures."""
    raw = jira_fields.get(field)
    if raw is None:
        return None
    if isinstance(raw, dict):
        return raw.get("name", raw.get("displayName", ""))
    return raw


def _map_jira_to_local_fields(jira_fields: dict[str, Any]) -> dict[str, Any]:
    """Map Jira fields to local ticket field names/values."""
    summary = _extract_jira_field_value(jira_fields, "summary") or ""
    description = _extract_jira_field_value(jira_fields, "description") or ""
    issuetype_raw = _extract_jira_field_value(jira_fields, "issuetype") or "Task"
    priority_raw = _extract_jira_field_value(jira_fields, "priority") or "Medium"
    status_raw = _extract_jira_field_value(jira_fields, "status") or "To Do"
    assignee = _extract_jira_field_value(jira_fields, "assignee") or ""

    return {
        "title": summary,
        "description": description,
        "ticket_type": _JIRA_TO_LOCAL_TYPE.get(issuetype_raw, "task"),
        "priority": _JIRA_TO_LOCAL_PRIORITY.get(priority_raw, 2),
        "status": _JIRA_TO_LOCAL_STATUS.get(status_raw, "open"),
        "assignee": assignee,
    }


def _diff_jira_vs_local(
    jira_fields: dict[str, Any],
    local_ticket: dict[str, Any],
) -> dict[str, Any]:
    """Compare Jira fields to local ticket. Return fields where Jira differs.

    Only returns fields where the Jira value (mapped to local conventions)
    differs from the current local value.
    """
    jira_mapped = _map_jira_to_local_fields(jira_fields)
    changed: dict[str, Any] = {}

    field_map = {
        "title": "title",
        "description": "description",
        "ticket_type": "ticket_type",
        "priority": "priority",
        "status": "status",
        "assignee": "assignee",
    }

    for local_field, ticket_field in field_map.items():
        jira_val = jira_mapped.get(local_field)
        local_val = local_ticket.get(ticket_field)
        # Normalise None to empty string for string fields
        if jira_val is None:
            jira_val = "" if local_field not in ("priority",) else 2
        if local_val is None:
            local_val = "" if local_field not in ("priority",) else 2
        if jira_val != local_val:
            changed[local_field] = jira_val
    return changed


# ---------------------------------------------------------------------------
# Label diff helpers
# ---------------------------------------------------------------------------

_EXCLUDED_PREFIXES: tuple[str, ...] = ("dso-id-", "imported:")


def _normalize_jira_body(body: Any) -> str:
    """Coerce a Jira comment body (ADF dict or string) to plain text.

    The reconciler marker token is preserved (callers filter on it).
    """
    if isinstance(body, dict):
        return _load_adf().adf_to_text(body)
    return str(body) if body is not None else ""


def _diff_comments_inbound(
    jira_fields: dict[str, Any], local_ticket: dict[str, Any]
) -> list[dict[str, Any]]:
    """Detect Jira-side comments not yet mirrored locally (bug 85a1, Gap 1).

    Strategy (validated by ``probe_gap1_inbound_comments.sh``):
      1. Read each Jira comment's id + body.
      2. Loop-breaker: skip any comment whose body contains
         ``RECONCILER_MARKER`` — that's our own outbound echo.
      3. Set-diff: skip any Jira comment whose id matches a local
         comment's ``jira_comment_id`` field (already mirrored).
      4. For each remaining Jira comment, emit an "add" mutation with
         the normalised plain-text body and the source jira_comment_id
         so the applier can write the binding back when persisting locally.

    Returns: list of dicts ``{"action": "add", "body": ..., "jira_comment_id": ...}``.
    The applier consumes this list when writing inbound updates to the
    local tickets-tracker.
    """
    jira_comments = jira_fields.get("comments") or []
    if not isinstance(jira_comments, list):
        return []

    known_ids: set[str] = set()
    for lc in local_ticket.get("comments") or []:
        if isinstance(lc, dict):
            jid = lc.get("jira_comment_id")
            if jid is not None:
                known_ids.add(str(jid))

    mutations: list[dict[str, Any]] = []
    for jc in jira_comments:
        if not isinstance(jc, dict):
            continue
        jid = jc.get("id")
        if jid is None:
            continue
        jid_str = str(jid)
        if jid_str in known_ids:
            continue  # already mirrored locally

        body_text = _normalize_jira_body(jc.get("body"))
        if RECONCILER_MARKER in body_text:
            continue  # outbound echo — do not pull our own comment back in
        if not body_text.strip():
            continue

        mutations.append(
            {
                "action": "add",
                "body": body_text,
                "jira_comment_id": jid_str,
            }
        )
    return mutations


def _diff_labels_inbound(
    jira_fields: dict[str, Any], local_ticket: dict[str, Any]
) -> list[dict[str, Any]]:
    """Compare Jira labels to local tags. Exclude bridge-internal labels."""
    jira_labels: set[str] = set(
        label
        for label in (jira_fields.get("labels") or [])
        if not any(label.startswith(p) for p in _EXCLUDED_PREFIXES)
    )
    local_tags: set[str] = set(
        t
        for t in local_ticket.get("tags", [])
        if not any(t.startswith(p) for p in _EXCLUDED_PREFIXES)
    )

    mutations: list[dict[str, Any]] = []
    for label in sorted(jira_labels - local_tags):
        mutations.append({"action": "add", "label": label})
    for label in sorted(local_tags - jira_labels):
        mutations.append({"action": "remove", "label": label})
    return mutations


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def compute_inbound_mutations(
    jira_snapshot: dict[str, dict[str, Any]],
    binding_store: BindingStoreProtocol,
    local_tickets_by_id: dict[str, dict[str, Any]],
) -> list[InboundMutation]:
    """Detect Jira-side changes for bound tickets.

    Only processes BOUND tickets (those in binding_store). Unbound Jira issues
    are ignored — they will be handled by outbound creates once the local
    ticket is synced outbound first.

    For bound tickets where Jira fields differ from local:
    - If local also changed -> skip (local wins, outbound differ handles it)
    - If only Jira changed -> emit inbound update

    The "local also changed" detection requires a baseline snapshot (previous
    sync state). Without a baseline, this implementation treats all local
    values as the baseline — meaning any difference between Jira and local
    is attributed to Jira having changed. The outbound differ's local-wins
    semantics ensure correctness: if both changed, the outbound differ will
    push the local value, and the inbound mutation (if emitted) will be
    superseded.

    Args:
        jira_snapshot: Dict of {jira_key: {fields...}} from the fetcher.
        binding_store: A BindingStore instance providing get_local_id(jira_key).
        local_tickets_by_id: Dict of {local_id: {ticket fields...}} for local
            ticket lookup.

    Returns:
        List of InboundMutation objects describing changes to apply locally.
    """
    mutations: list[InboundMutation] = []

    for jira_key, jira_fields in sorted(jira_snapshot.items()):
        local_id = binding_store.get_local_id(jira_key)
        if local_id is None:
            # Unbound Jira issue — skip (local is source of truth)
            continue

        local_ticket = local_tickets_by_id.get(local_id)
        if local_ticket is None:
            # Bound but local ticket missing — skip (may be deleted locally)
            continue

        changed = _diff_jira_vs_local(jira_fields, local_ticket)
        label_mutations = _diff_labels_inbound(jira_fields, local_ticket)
        comment_mutations = _diff_comments_inbound(jira_fields, local_ticket)

        if changed or label_mutations or comment_mutations:
            mutations.append(
                InboundMutation(
                    jira_key=jira_key,
                    local_id=local_id,
                    action="update",
                    fields=changed,
                    labels=label_mutations,
                    comments=comment_mutations,
                )
            )

    return mutations
