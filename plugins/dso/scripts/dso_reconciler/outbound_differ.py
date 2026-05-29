"""Outbound differ for bidirectional Jira sync.

Compares local ticket state against the Jira working-set snapshot and emits
a list of OutboundMutation objects describing changes to push from local to
Jira. Uses a BindingStore (from PR #401) to map local ticket IDs to Jira keys.

Local is the source of truth. Unbound local tickets emit "create" mutations;
bound tickets whose fields diverge from Jira emit "update" mutations with
only the changed fields.

This module is pure: no I/O, no time/random, no logging, no globals.

Dependency: BindingStore interface (PR #401). This module codes against the
interface — get_jira_key(local_id) -> str|None, is_bound(local_id) -> bool —
and does not import the concrete class.
"""

from __future__ import annotations

import importlib.util
import sys
from dataclasses import dataclass, field as dataclass_field
from pathlib import Path
from typing import Any, Protocol, runtime_checkable


_ADF_KEY = "plugins.dso.scripts.dso_reconciler.adf"
_AdfModule = None


def _load_adf():
    """Lazy-load the sibling adf module.

    The differ may be imported either as a normal package module (production)
    or via ``importlib.util.spec_from_file_location`` (tests). The latter
    does not establish package context, so ``from . import adf`` fails. Use
    the canonical dotted sys.modules key (same pattern as applier's
    _load_mutation_module) so the module is loaded exactly once across all
    callers.
    """
    global _AdfModule
    if _AdfModule is not None:
        return _AdfModule
    if _ADF_KEY in sys.modules:
        _AdfModule = sys.modules[_ADF_KEY]
        return _AdfModule
    adf_path = Path(__file__).parent / "adf.py"
    spec = importlib.util.spec_from_file_location(_ADF_KEY, adf_path)
    if spec is None or spec.loader is None:
        raise FileNotFoundError(f"adf.py not found at {adf_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[_ADF_KEY] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    _AdfModule = mod
    return mod


# ---------------------------------------------------------------------------
# BindingStore protocol — codes against PR #401's interface
# ---------------------------------------------------------------------------


@runtime_checkable
class BindingStoreProtocol(Protocol):
    """Minimal interface for the binding store (PR #401)."""

    def get_jira_key(self, local_id: str) -> str | None: ...
    def is_bound(self, local_id: str) -> bool: ...


# ---------------------------------------------------------------------------
# OutboundMutation dataclass
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OutboundMutation:
    """A single outbound change to push to Jira."""

    local_id: str
    jira_key: str | None  # None for create (not yet assigned)
    action: str  # "create" | "update" | "delete"
    fields: dict[str, Any]  # changed fields only for update; all fields for create
    comments: list[dict[str, Any]] = dataclass_field(default_factory=list)
    labels: list[dict[str, Any]] = dataclass_field(default_factory=list)
    links: list[dict[str, Any]] = dataclass_field(default_factory=list)


# ---------------------------------------------------------------------------
# Field mapping constants
# ---------------------------------------------------------------------------

_LOCAL_TO_JIRA_TYPE: dict[str, str] = {
    "bug": "Bug",
    "story": "Story",
    "task": "Task",
    "epic": "Epic",
}

_LOCAL_TO_JIRA_PRIORITY: dict[int, str] = {
    0: "Highest",
    1: "High",
    2: "Medium",
    3: "Low",
    4: "Lowest",
}

_LOCAL_TO_JIRA_STATUS: dict[str, str] = {
    "open": "To Do",
    "in_progress": "In Progress",
    "blocked": "Blocked",
    "closed": "Done",
    "cancelled": "Cancelled",
    "deleted": "Done",
}


# ---------------------------------------------------------------------------
# Field mapping helpers
# ---------------------------------------------------------------------------


def _map_local_to_jira_fields(ticket: dict[str, Any]) -> dict[str, Any]:
    """Map local ticket fields to Jira field names/values.

    Use ``.get(key) or default`` (not ``.get(key, default)``) for string
    fields so an explicit ``None`` value normalises to the empty-string
    default. ``.get(key, default)`` only falls back when the key is
    MISSING — if the key exists with value ``None`` (e.g. unassigned
    tickets where the ticket reducer initialises ``assignee: None``),
    .get returns None, not the default. None then propagates through
    ``_diff_fields`` and becomes the literal string ``"None"`` after
    str() conversion at the ACLI boundary, causing ACLI to reject the
    edit with exit 1.
    """
    return {
        "summary": ticket.get("title") or "",
        "description": ticket.get("description") or "",
        "issuetype": _LOCAL_TO_JIRA_TYPE.get(ticket.get("ticket_type", "task"), "Task"),
        "priority": _LOCAL_TO_JIRA_PRIORITY.get(ticket.get("priority", 2), "Medium"),
        "status": _LOCAL_TO_JIRA_STATUS.get(ticket.get("status", "open"), "To Do"),
        "assignee": ticket.get("assignee") or "",
    }


def _extract_jira_field(jira_fields: dict[str, Any], field: str) -> Any:
    """Extract a Jira field value, handling nested structures.

    Jira API returns some fields as nested objects (priority.name,
    issuetype.name, status.name, assignee.displayName), and description is
    returned as an Atlassian Document Format (ADF) dict, not a plain string.

    Bug 85a1: before this fix, description ADF dicts were extracted as
    ``""`` because the generic ``raw.get("name", raw.get("displayName", ""))``
    fallback found neither key on ADF (``{"type": "doc", "version": 1,
    "content": [...]}``). The differ then reported description as changed on
    every pass for every bound ticket — the 21-mutation idempotency churn
    documented in the e2e probe Phase 6.

    Fix: dispatch by field name. Description ADF dicts are decoded via
    ``adf.adf_to_text``; assignee continues to return ``displayName`` (the
    canonical form local probe tickets store); priority / status / issuetype
    use the existing ``.name`` extraction. Plain string values (including
    legacy snapshots from before ADF migration) pass through unchanged.
    """
    raw = jira_fields.get(field)
    if raw is None:
        return ""

    # Description: ADF dict → plain text via the project's ADF walker.
    if field == "description":
        if isinstance(raw, dict):
            return _load_adf().adf_to_text(raw)
        return raw  # legacy plain-string snapshot

    if isinstance(raw, dict):
        # Jira nested objects: {name: ..., id: ...}
        return raw.get("name", raw.get("displayName", ""))
    return raw


def _assignee_matches(local_val: str, jira_raw: Any) -> bool:
    """Permissive assignee equality (bug 85a1, Gap 4).

    Jira returns assignee as a dict with at least ``{accountId, displayName,
    emailAddress}``; local tickets store assignee as a bare string that may
    be an email (ticket-create.sh default), a displayName (probe), or
    "Test" (git-config default), depending on how the ticket was made.
    A direct ``local_val == _extract_jira_field(...)`` comparison fires on
    every pass for any user not stored under the same identity form as
    Jira returns — Phase 6 idempotency churn AND spurious outbound updates.

    Treat ``local_val`` as matching when it equals ANY of {emailAddress,
    accountId, displayName}. Both sides empty (unassigned) also match.
    """
    if jira_raw is None:
        return local_val == ""
    if not isinstance(jira_raw, dict):
        return local_val == str(jira_raw)
    candidates = {
        (jira_raw.get("emailAddress") or "").strip(),
        (jira_raw.get("accountId") or "").strip(),
        (jira_raw.get("displayName") or "").strip(),
    }
    candidates.discard("")
    return (local_val or "").strip() in candidates


def _diff_fields(ticket: dict[str, Any], jira_fields: dict[str, Any]) -> dict[str, Any]:
    """Compare local ticket to Jira fields. Return only changed fields.

    Uses local-wins: if local differs, push outbound regardless of Jira state.
    Assignee comparison is shape-tolerant via ``_assignee_matches`` so
    Jira's ``{accountId, displayName, emailAddress}`` dict matches a local
    string in any of those three forms (bug 85a1, Gap 4).

    Bug b859 (Part 0d): when ``DSO_RECONCILER_VERBOSE=1`` is set, emit a
    one-line RECON record per detected field-diff with truncated local /
    jira values so operators can debug parity issues directly from the
    probe's side-car log. Off by default to keep production stderr quiet.
    """
    import os
    import sys
    verbose = os.environ.get("DSO_RECONCILER_VERBOSE", "0") == "1"
    ticket_id = ticket.get("ticket_id") or ticket.get("id") or "<no-id>"

    local_mapped = _map_local_to_jira_fields(ticket)
    changed: dict[str, Any] = {}
    for field_name, local_val in local_mapped.items():
        if field_name == "assignee":
            if not _assignee_matches(local_val, jira_fields.get("assignee")):
                changed[field_name] = local_val
                if verbose:
                    print(  # noqa: T201
                        f"RECON: field_diff ticket={ticket_id} "
                        f"field=assignee local={local_val!r:.80} "
                        f"jira={jira_fields.get('assignee')!r:.80}",
                        file=sys.stderr,
                    )
            continue
        jira_val = _extract_jira_field(jira_fields, field_name)
        if local_val != jira_val:
            changed[field_name] = local_val
            if verbose:
                # Truncate value repr to keep one-line records reasonable.
                _l = repr(local_val)
                _j = repr(jira_val)
                if len(_l) > 80:
                    _l = _l[:77] + "..."
                if len(_j) > 80:
                    _j = _j[:77] + "..."
                print(  # noqa: T201
                    f"RECON: field_diff ticket={ticket_id} "
                    f"field={field_name} local={_l} jira={_j}",
                    file=sys.stderr,
                )
    return changed


# ---------------------------------------------------------------------------
# Comment diff
# ---------------------------------------------------------------------------


def _map_comments_for_create(ticket: dict[str, Any]) -> list[dict[str, Any]]:
    """Map all local comments to outbound create mutations.

    Every outbound body is decorated with the reconciler marker (Gap 1
    loop-breaker) so inbound passes can identify our own echoes.
    """
    comments = ticket.get("comments", [])
    return [
        {"action": "add", "body": _decorate_outbound_comment(c.get("body", ""))}
        for c in comments
    ]


# Bug 85a1 (Gap 1): marker token embedded in every outbound comment body
# so the inbound differ can identify and filter our own echoes when the
# reconciler reads Jira comments back on the next pass. Without the marker
# every outbound comment would re-appear inbound as a "new Jira comment"
# and the bridge would loop. Kept identical here and in inbound_differ.py
# so both directions agree on the loop-breaker pattern.
RECONCILER_MARKER = "<!-- dso:reconciler-echo -->"


def _normalize_comment_body(body: Any) -> str:
    """Coerce a comment body to a comparable plain-text string.

    Jira comments are returned with ``body`` as an Atlassian Document Format
    (ADF) dict (``{"type": "doc", ...}``). Local comments store ``body`` as a
    plain string. Direct dict-vs-string comparison always reports them as
    different — driving spurious duplicate pushes (Phase 2 verify-no-
    duplicate-comments: "found 2 copies") and the dict-as-key crash in
    ``_diff_comments`` (Phase 3+ "unhashable type: 'dict'" when an ADF body
    flows into a ``set[str]`` insertion).

    Normalize via ``adf.adf_to_text`` so the canonical comparison is on
    text. Bug 85a1. The reconciler marker token (Gap 1) is also stripped
    so dedup compares the *user content* on both sides — without the strip,
    a previously-pushed Jira body ``"hello\\n\\n<marker>"`` would never match
    a local ``"hello"`` and the diff would re-emit the same comment.
    """
    if isinstance(body, dict):
        text = _load_adf().adf_to_text(body)
    else:
        text = str(body) if body is not None else ""
    return text.replace(RECONCILER_MARKER, "").strip()


def _decorate_outbound_comment(body: str) -> str:
    """Append the reconciler marker to an outbound comment body (Gap 1).

    Two paragraphs of separation keeps the marker visually below the user
    content. The marker survives ADF round-trip (each paragraph maps to
    its own ADF node and back).
    """
    return f"{body}\n\n{RECONCILER_MARKER}"


def _diff_comments(
    ticket: dict[str, Any],
    jira_key: str,
    jira_snapshot: dict[str, Any],
) -> list[dict[str, Any]]:
    """Compare local comments to Jira comments. Return mutations for new comments.

    Simple strategy: detect local comments not yet mirrored to Jira by
    comparing comment bodies. This is a best-effort approach; PR #402
    (ADF walker + comment binding) will provide exact comment ID binding.
    Bodies are normalized via :func:`_normalize_comment_body` so a Jira
    ADF body matches its local plain-text counterpart (bug 85a1).
    """
    local_comments = ticket.get("comments", [])
    jira_issue = jira_snapshot.get(jira_key, {})
    jira_comments = jira_issue.get("comments", [])

    jira_bodies: set[str] = set()
    for c in jira_comments:
        raw = c.get("body", "") if isinstance(c, dict) else c
        jira_bodies.add(_normalize_comment_body(raw))

    mutations: list[dict[str, Any]] = []
    for c in local_comments:
        raw = c.get("body", "") if isinstance(c, dict) else c
        body = _normalize_comment_body(raw)
        if body and body not in jira_bodies:
            # Decorate the outbound body with the reconciler marker so the
            # inbound differ can identify (and filter) our own echoes on the
            # next pass (Gap 1 loop-breaker).
            mutations.append(
                {"action": "add", "body": _decorate_outbound_comment(body)}
            )
    return mutations


# ---------------------------------------------------------------------------
# Label diff
# ---------------------------------------------------------------------------

_EXCLUDED_PREFIXES: tuple[str, ...] = ("dso-id-", "imported:")


def _diff_labels(
    ticket: dict[str, Any], jira_fields: dict[str, Any]
) -> list[dict[str, Any]]:
    """Compare local tags to Jira labels. Exclude bridge-internal labels."""
    local_tags: set[str] = set(
        t
        for t in ticket.get("tags", [])
        if not any(t.startswith(p) for p in _EXCLUDED_PREFIXES)
    )
    jira_labels: set[str] = set(
        label
        for label in (jira_fields.get("labels") or [])
        if not any(label.startswith(p) for p in _EXCLUDED_PREFIXES)
    )

    mutations: list[dict[str, Any]] = []
    for label in sorted(local_tags - jira_labels):
        mutations.append({"action": "add", "label": label})
    for label in sorted(jira_labels - local_tags):
        mutations.append({"action": "remove", "label": label})
    return mutations


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def compute_outbound_mutations(
    local_tickets: list[dict[str, Any]],
    jira_snapshot: dict[str, Any],
    binding_store: BindingStoreProtocol,
    excluded_statuses: set[str] | None = None,
) -> list[OutboundMutation]:
    """Diff local tickets against Jira snapshot and return outbound mutations.

    Args:
        local_tickets: List of local ticket dicts. Each has: ticket_id, title,
            description, status, priority, ticket_type, assignee, tags, comments,
            deps.
        jira_snapshot: Dict of {jira_key: {fields...}} from the fetcher.
        binding_store: A BindingStore instance providing get_jira_key(local_id),
            is_bound(local_id).
        excluded_statuses: Statuses to skip (default: {"archived", "deleted"}).

    Returns:
        List of OutboundMutation objects describing changes to push to Jira.
    """
    if excluded_statuses is None:
        excluded_statuses = {"archived", "deleted"}

    mutations: list[OutboundMutation] = []

    for ticket in local_tickets:
        status = ticket.get("status", "")
        if status in excluded_statuses:
            continue

        local_id = ticket["ticket_id"]
        jira_key = binding_store.get_jira_key(local_id)

        if jira_key is None:
            # Unbound -> outbound create
            mutations.append(
                OutboundMutation(
                    local_id=local_id,
                    jira_key=None,
                    action="create",
                    fields=_map_local_to_jira_fields(ticket),
                    comments=_map_comments_for_create(ticket),
                    labels=[
                        {"action": "add", "label": t}
                        for t in sorted(ticket.get("tags", []))
                        if not any(t.startswith(p) for p in _EXCLUDED_PREFIXES)
                    ],
                    links=[],  # links resolved after all creates
                )
            )
        else:
            # Bound -> compare fields, emit update if different
            jira_fields = jira_snapshot.get(jira_key, {})
            changed = _diff_fields(ticket, jira_fields)
            comment_mutations = _diff_comments(ticket, jira_key, jira_snapshot)
            label_mutations = _diff_labels(ticket, jira_fields)

            if changed or comment_mutations or label_mutations:
                mutations.append(
                    OutboundMutation(
                        local_id=local_id,
                        jira_key=jira_key,
                        action="update",
                        fields=changed,
                        comments=comment_mutations,
                        labels=label_mutations,
                        links=[],
                    )
                )

    return mutations
