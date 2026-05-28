#!/usr/bin/env python3
"""Applier: dispatches mutations to AcliClient and writes per-pass flat-JSON manifest.

TODO(follow-up): this module is 586 lines, exceeding the 500-line module-size
threshold. The intended split is:
    - mapping_io.py   — _load_mapping, _write_mapping_atomic, _write_mapping_json_atomic,
                        _persist_field_provenance
    - retry.py        — _call_with_retry, JiraAPIError, RetryExhaustedError
    - dispatchers.py  — create_one, update_one, delete_one
leaving applier.py with just the public apply() orchestrator + RescheduleError +
_handle_failed_write_result. The refactor was deferred from PR #290 because the
mechanical move + import-graph fixup is too large for the current PR. Track via
a follow-up bug ticket before the next applier-touching change.
"""

from __future__ import annotations

import contextlib
import importlib.util
import json
import logging
import os
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

logger = logging.getLogger(__name__)

# Typed-mutation dispatch layer.
#
# The applier was originally written as a single batch-style apply(mutations,
# pass_id, ...) routine over dict-shaped mutations. The narrow-applier-matrix
# story introduces a typed Mutation value object (mutation.Mutation with
# MutationDirection / MutationAction enums) and a per-leaf dispatch registry
# (_LEAVES) so callers can route a single Mutation through exactly one
# direction/action handler.
#
# The two surfaces coexist:
#   - apply(mutation: Mutation, *, client=None) -> ApplyResult
#       Typed single-mutation dispatch via _LEAVES.
#   - apply(mutations: list[dict], pass_id, repo_root=None) -> Path
#       Legacy batch dispatch (manifest writer + HEAD-drift guard).
#
# Selection is by argument type at the top of apply().
_MutationModule = (
    None  # late-loaded mutation module; written by _load_mutation_module()
)
_ErrorsModule = None  # late-loaded _errors module; written by _load_errors_module()


@dataclass(frozen=True, slots=True)
class ApplyResult:
    """Result of a typed-mutation apply() dispatch.

    direction/action mirror the Mutation that was dispatched, so callers can
    confirm which leaf executed without re-reading the input. payload carries
    any leaf-specific return data (empty dict by default for the stub leaves).
    """

    direction: Any
    action: Any
    payload: dict[str, Any]


_MUTATION_KEY = "plugins.dso.scripts.dso_reconciler.mutation"


def _load_mutation_module():
    """Lazy-load the mutation module under the canonical dotted sys.modules key.

    Uses the SAME key (``plugins.dso.scripts.dso_reconciler.mutation``) as
    invariants.py and differ.py so ``Mutation`` / ``MutationDirection`` /
    ``MutationAction`` retain a single class identity across the reconciler.
    Previously each caller loaded under its own private key, producing distinct
    class objects per module — ``isinstance`` and ``is`` comparisons silently
    crossed boundaries and routed mutations to the wrong leaf.
    """
    global _MutationModule
    if _MutationModule is not None:
        return _MutationModule
    if _MUTATION_KEY in sys.modules:
        _MutationModule = sys.modules[_MUTATION_KEY]
        return _MutationModule
    mut_path = Path(__file__).parent / "mutation.py"
    spec = importlib.util.spec_from_file_location(_MUTATION_KEY, mut_path)
    if spec is None:
        raise FileNotFoundError(f"mutation.py not found at {mut_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[_MUTATION_KEY] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    _MutationModule = mod
    return mod


def _load_errors_module():
    """Lazy-load _errors module."""
    global _ErrorsModule
    if _ErrorsModule is not None:
        return _ErrorsModule
    err_path = Path(__file__).parent / "_errors.py"
    spec = importlib.util.spec_from_file_location("dso_reconciler_errors", err_path)
    if spec is None:
        raise FileNotFoundError(f"_errors.py not found at {err_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("dso_reconciler_errors", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    _ErrorsModule = mod
    return mod


# Re-export error classes so callers can import them from applier.py.
# Internal uses still go through _load_errors_module() to preserve lazy-load
# semantics; these module-level names exist for the public import surface.
_errors_module = _load_errors_module()
StatusMappingError = _errors_module.StatusMappingError
DirectionMismatchError = _errors_module.DirectionMismatchError
UnknownActionError = _errors_module.UnknownActionError
DsoIdLabelWriteError = _errors_module.DsoIdLabelWriteError


def _direction_guard(mutation, expected_direction) -> None:
    """Defense-in-depth: assert mutation.direction matches the leaf's declared
    direction. In normal flow _LEAVES lookup already routes correctly; this
    raises DirectionMismatchError if a leaf is invoked directly with the wrong
    direction (e.g. via the test harness bypassing _LEAVES).

    Compare by string value rather than identity. The reconciler loads
    mutation.py multiple times via importlib (once per importing module), and
    each load creates a distinct MutationDirection enum class. Two enum
    members with the same value but from different class instances are NOT
    identity-equal, so ``is not`` would fire spuriously on filtered passes
    where a Mutation built under one module load reaches a leaf imported
    under another.
    """
    expected_val = expected_direction.value
    actual_val = getattr(mutation.direction, "value", mutation.direction)
    if expected_val != actual_val:
        errs = _load_errors_module()
        raise errs.DirectionMismatchError(
            f"leaf expects direction={expected_val!s}, "
            f"got direction={actual_val!s}"
        )


# ---------------------------------------------------------------------------
# Per-leaf stub handlers.
#
# Each leaf:
#   1. Calls _direction_guard() with its own declared direction (defense-in-depth).
#   2. Performs the leaf-specific side effect (currently stubbed — real ACLI
#      wiring lands in a follow-on task).
#   3. Returns an ApplyResult.
# ---------------------------------------------------------------------------


def _apply_outbound_create(mutation, *, client=None, repo_root=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)
    if client is None:
        # Stub path: preserved for tests that don't exercise the I/O leaf.
        return ApplyResult(mutation.direction, mutation.action, {})
    payload = dict(mutation.payload)
    try:
        _call_with_retry(client.create_issue, payload)
    except Exception:
        # Rollback path: if a Jira issue was (likely) created before the failure
        # surfaced, delete it via the same retry helper so transient delete
        # failures are also retried. Swallow any rollback error so the ORIGINAL
        # create exception is what re-raises to the caller.
        key = payload.get("key_hint") or mutation.target
        try:
            _call_with_retry(client.delete_issue, key)
        except Exception:  # noqa: BLE001
            # Best-effort rollback: swallow delete errors so the original
            # create exception propagates to the caller unchanged.
            pass
        raise
    return ApplyResult(mutation.direction, mutation.action, {})


# Allowlist of fields that can be pushed outbound via update_issue. Other
# fields in the changed_fields set are silently dropped — pushing arbitrary
# fields outbound is a higher-blast-radius change that lands in a follow-up
# story. Status is governed separately by DSO_RECONCILER_STATUS_GATING.
_OUTBOUND_UPDATE_ALLOWLIST = frozenset({"summary", "description", "assignee", "priority"})


def _route_status_via_draft5(mutation, *, client=None):
    """Stub for status routing via draft5 protocol.

    The final implementation of outbound status push (transition mapping,
    workflow-state lookup, etc.) lands in a later epic. v1 just acknowledges
    the dispatch so the gating contract is exercised end-to-end.
    """
    # Intentionally a no-op stub. Real impl arrives with the status-push story.
    return None


def _apply_outbound_update(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """v1 outbound update — push allowlisted fields via update_issue.

    Behavior:
      - Reads ``mutation.payload['changed_fields']`` (falls back to
        ``mutation.payload`` itself for callers that pass a flat dict).
      - If ``status`` is present in changed_fields:
          - When ``DSO_RECONCILER_STATUS_GATING != "1"``: raise
            ``StatusMappingError`` with zero side-effects.
          - When ``DSO_RECONCILER_STATUS_GATING == "1"``: delegate to
            ``_route_status_via_draft5`` and strip ``status`` from the field
            set before pushing the remaining allowlisted fields.
      - Filters the field set to ``_OUTBOUND_UPDATE_ALLOWLIST``; non-allowlisted
        fields are silently dropped (no side-effects on those fields).
      - Pushes the allowlisted, non-status fields via ``client.update_issue``
        using the F3-pinned ``update_issue(jira_key, **fields)`` signature,
        routed through ``_call_with_retry``.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)

    if client is None:
        # Stub path: preserved for tests that don't exercise the I/O leaf.
        return ApplyResult(mutation.direction, mutation.action, {})

    payload = dict(mutation.payload or {})
    changed_fields = payload.get("changed_fields")
    if changed_fields is None:
        changed_fields = payload

    # Status gating: status field is governed by DSO_RECONCILER_STATUS_GATING.
    if "status" in changed_fields:
        gating = os.environ.get("DSO_RECONCILER_STATUS_GATING", "0")
        if gating != "1":
            errs = _load_errors_module()
            raise errs.StatusMappingError(
                f"status field touched but DSO_RECONCILER_STATUS_GATING != 1 "
                f"(got {gating!r}); zero side-effects — refusing to push status "
                "without explicit operator gating"
            )
        # Gating ON — delegate to the draft5 stub. The caller is responsible
        # for any status-specific routing semantics.
        _route_status_via_draft5(mutation, client=client)
        # Strip status before pushing remaining allowlisted fields.
        changed_fields = {k: v for k, v in changed_fields.items() if k != "status"}

    # Filter to allowlist. Non-allowlisted fields are silently dropped.
    allowed = {
        k: v for k, v in changed_fields.items() if k in _OUTBOUND_UPDATE_ALLOWLIST
    }
    if allowed:
        _call_with_retry(client.update_issue, mutation.target, **allowed)
    return ApplyResult(
        mutation.direction,
        mutation.action,
        {"fields_pushed": sorted(allowed.keys())},
    )


def _apply_outbound_delete(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Outbound delete: route through the legacy batch path's delete_one()
    when a client is supplied. Typed-mutation callers can also drive a direct
    delete via this leaf.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)
    if client is None:
        # Stub path: preserved for tests that don't exercise the I/O leaf.
        return ApplyResult(mutation.direction, mutation.action, {})
    try:
        _call_with_retry(client.delete_issue, mutation.target)
    except JiraAPIError as exc:
        if getattr(exc, "status_code", None) == 404:
            # Already-gone is the post-state we want — treat as success.
            return ApplyResult(
                mutation.direction, mutation.action, {"already_gone": True}
            )
        raise
    return ApplyResult(
        mutation.direction, mutation.action, {"deleted": mutation.target}
    )


def _apply_outbound_probe(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Outbound probe: read-only sanity check via client.get_issue when supplied.

    Returns the probe outcome (key + present flag) in the result payload so
    upstream callers can branch on the live Jira state.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)
    if client is None or not hasattr(client, "get_issue"):
        return ApplyResult(mutation.direction, mutation.action, {})
    try:
        info = _call_with_retry(client.get_issue, mutation.target)
        return ApplyResult(
            mutation.direction,
            mutation.action,
            {"present": True, "issue": info if isinstance(info, dict) else {}},
        )
    except JiraAPIError as exc:
        if getattr(exc, "status_code", None) in (404, 410, 403):
            return ApplyResult(mutation.direction, mutation.action, {"present": False})
        raise


def _apply_outbound_conflict(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Outbound conflict: emit a structured conflict-marker comment on the Jira
    issue when a client is supplied. Conflicts are durable signals — the
    follow-on is consumed by reconcile_once via the standard suppress_pair
    channel so the same pair is not retried mid-pass.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)
    payload = dict(mutation.payload or {})
    if client is not None and hasattr(client, "add_comment"):
        try:
            _call_with_retry(
                client.add_comment,
                mutation.target,
                f"reconciler conflict detected: {payload.get('reason', 'unspecified')}",
            )
        except Exception:
            # Best-effort comment; do not propagate — the suppress_pair
            # follow-on still informs reconcile_once to drop further work.
            pass
    follow_on = {
        "kind": "suppress_pair",
        "local_id": payload.get("local_id", ""),
        "jira_key": mutation.target,
    }
    return ApplyResult(mutation.direction, mutation.action, {"follow_on": follow_on})


# ---------------------------------------------------------------------------
# Inbound leaf-body helpers (story bd19-d744-b8c7-4079)
#
# Inbound leaves write local ticket-tracker events directly because the local
# CLI is the authoritative reader and we want deterministic file-shape control.
# Event files follow the format documented at
# ${CLAUDE_PLUGIN_ROOT}/docs/ticket-system-v3-architecture.md and mirrored
# throughout the tracker dir as <ticket_id>/<ts>-<uuid>-<EVENT>.json.
# ---------------------------------------------------------------------------

# Map Jira issuetype -> local ticket_type. Anything else falls through to 'task'.
_JIRA_TYPE_MAP: dict[str, str] = {
    "Bug": "bug",
    "Story": "story",
    "Task": "task",
    "Epic": "epic",
    "Sub-task": "task",
}

_JIRA_PRIORITY_MAP: dict[str, int] = {
    "Highest": 0,
    "High": 1,
    "Medium": 2,
    "Low": 3,
    "Lowest": 4,
}

_VALID_PRIORITY_RANGE = range(0, 5)  # 0-4 inclusive


def _resolve_priority(raw_pri: Any) -> int:
    """Convert a Jira priority (name-string or int) to a local 0-4 integer.

    Integers outside 0-4 are clamped to the default (2 / Medium).
    Unrecognised name strings also fall back to 2.
    """
    if isinstance(raw_pri, int):
        return raw_pri if raw_pri in _VALID_PRIORITY_RANGE else 2
    pri_name = _extract_name(raw_pri)
    return _JIRA_PRIORITY_MAP.get(pri_name, 2)


def _jira_key_to_local_id(jira_key: str) -> str:
    """DIG-123 -> jira-dig-123. Idempotent for already-prefixed local ids."""
    if jira_key.startswith("jira-"):
        return jira_key
    return "jira-" + jira_key.lower()


def _jira_status_to_local(jira_status: str) -> str:
    """Reverse-map a Jira status to a local status using config.local_to_jira_status.

    Ambiguous reverse mappings (multiple local statuses → same Jira status) are
    resolved by lexicographic ordering of the local key, documented in
    Implementation Notes of story bd19.
    """
    if not jira_status:
        return "open"
    try:
        # Late-load config without polluting module namespace.
        config_path = Path(__file__).parent / "config.py"
        spec = importlib.util.spec_from_file_location(
            "dso_reconciler_config", config_path
        )
        if spec is None or spec.loader is None:
            return "open"
        cfg_mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cfg_mod)  # type: ignore[union-attr]
        mapping = getattr(cfg_mod, "local_to_jira_status", {}) or {}
    except Exception:
        return "open"
    candidates = sorted(local for local, jira in mapping.items() if jira == jira_status)
    return candidates[0] if candidates else "open"


def _event_meta() -> tuple[int, str, str, str]:
    """Return (timestamp_ns, uuid4_str, env_id, author) for a new event."""
    import time as _time
    import uuid as _uuid

    return (
        _time.time_ns(),
        str(_uuid.uuid4()),
        os.environ.get("DSO_ENV_ID", "reconciler"),
        os.environ.get("DSO_AUTHOR", "reconciler"),
    )


def _resolve_tracker_dir(repo_root: Path | None) -> Path:
    """Resolve the .tickets-tracker directory. Honours TICKETS_TRACKER_DIR env."""
    override = os.environ.get("TICKETS_TRACKER_DIR")
    if override:
        return Path(override)
    if repo_root is None:
        repo_root = Path(__file__).parents[4]
    return Path(repo_root) / ".tickets-tracker"  # tickets-boundary-ok


def _read_latest_status(tracker_dir: Path, ticket_id: str) -> str:
    """Return the latest status recorded for ``ticket_id`` (default ``"open"``).

    Mirrors the reducer's STATUS-processing semantics (see
    ticket_reducer/_processors.py:process_status):
    the reducer initialises ``state["status"]`` to ``"open"`` and advances it
    only when a STATUS event arrives whose own ``current_status`` field
    matches the current state. Reading the latest written ``data["status"]``
    here gives the inbound leaf the value that the reducer would have in
    state right before our new STATUS event lands, so the new event's
    ``current_status`` is the PREVIOUS state (not the new one).

    Tolerant of missing tickets and unreadable event files — returns
    ``"open"`` in either case, matching the reducer's initial state.
    """
    ticket_dir = tracker_dir / ticket_id
    if not ticket_dir.is_dir():
        return "open"
    latest_status = "open"
    for ef in sorted(ticket_dir.glob("*.json")):
        try:
            event = json.loads(ef.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            continue
        if not isinstance(event, dict):
            continue
        if event.get("event_type") == "STATUS":
            latest_status = event.get("data", {}).get("status", "") or latest_status
    return latest_status


def _write_event_file(
    tracker_dir: Path, ticket_id: str, event_type: str, data: dict[str, Any]
) -> Path:
    """Write a single ticket event JSON file. Returns the path written."""
    ts, uuid_str, env_id, author = _event_meta()
    event = {
        "timestamp": ts,
        "uuid": uuid_str,
        "event_type": event_type,
        "env_id": env_id,
        "author": author,
        "data": data,
    }
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)
    fname = f"{ts}-{uuid_str}-{event_type}.json"
    out = ticket_dir / fname
    out.write_text(json.dumps(event, ensure_ascii=False), encoding="utf-8")
    return out


def _extract_name(val, default=""):
    """Extract .name or .displayName from a nested Jira field object.

    Jira REST API returns many fields as nested objects (e.g.
    ``{"name": "Bug", "id": "10002"}``). This helper extracts the human-readable
    name, falling back to the raw value when it is already a string.
    """
    if isinstance(val, dict):
        return val.get("name") or val.get("displayName") or default
    return val or default


def _apply_inbound_create(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Materialise a remote Jira issue as a local jira-* ticket.

    Writes a CREATE event (title, ticket_type, priority, description, tags
    including ``imported:reconciler-bootstrap``) and, when the payload carries
    a non-default status, a follow-up STATUS event reverse-mapped via
    config.local_to_jira_status.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)

    payload = dict(mutation.payload or {})
    # Accept both shapes: payload with nested "fields" key (batch-dict shape)
    # and payload with top-level field keys (differ Mutation shape).
    fields = payload.get("fields") or payload
    jira_key = mutation.target
    local_id = _jira_key_to_local_id(jira_key)
    issuetype = _extract_name(fields.get("issuetype"), "Task")
    ticket_type = _JIRA_TYPE_MAP.get(issuetype, "task")

    tracker_dir = _resolve_tracker_dir(repo_root)
    tags = list(payload.get("labels", []) or [])
    if "imported:reconciler-bootstrap" not in tags:
        tags.append("imported:reconciler-bootstrap")
    create_data: dict[str, Any] = {
        "id": local_id,
        "ticket_type": ticket_type,
        "title": fields.get("summary", "") or jira_key,
        "description": fields.get("description", "") or "",
        "parent_id": "",
        "tags": tags,
    }
    if "priority" in fields:
        create_data["priority"] = _resolve_priority(fields["priority"])
    if fields.get("assignee"):
        create_data["assignee"] = _extract_name(fields["assignee"])
    create_path = _write_event_file(tracker_dir, local_id, "CREATE", create_data)

    # Status: write a STATUS event when the Jira status reverse-maps to
    # something other than the reducer default ('open').
    jira_status = _extract_name(fields.get("status"))
    if jira_status:
        local_status = _jira_status_to_local(jira_status)
        if local_status and local_status != "open":
            _write_event_file(
                tracker_dir,
                local_id,
                "STATUS",
                {"status": local_status, "current_status": "open"},
            )

    # Write dso-id label + dso_local_id entity property back to Jira so the
    # differ recognizes this issue as mirrored on subsequent passes (dedup).
    if client is not None:
        _call_with_retry(client.add_label, jira_key, f"dso-id:{local_id}")
        _call_with_retry(client.set_entity_property, jira_key, "dso_local_id", local_id)

    return ApplyResult(
        mutation.direction,
        mutation.action,
        {"local_id": local_id, "create_event": str(create_path)},
    )


def _apply_inbound_update(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Apply a remote-side update to an existing local jira-* ticket.

    Writes one EDIT event with the changed fields, plus an additional STATUS
    event when the payload includes a Jira status change. Unknown ticket
    directories are tolerated (the EDIT is still written; the reducer will
    surface fsck on the next read).
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)

    payload = dict(mutation.payload or {})
    # Accept both shapes: payload with nested "fields" key (batch-dict shape)
    # and payload with top-level field keys (differ Mutation shape).
    fields = payload.get("fields") or payload
    target = mutation.target
    local_id = target if target.startswith("jira-") else _jira_key_to_local_id(target)
    tracker_dir = _resolve_tracker_dir(repo_root)

    # Map Jira-flavoured field names to local reducer field names.
    # Extract .name/.displayName from nested Jira objects.
    edit_fields: dict[str, Any] = {}
    if "summary" in fields:
        edit_fields["title"] = fields["summary"]
    if "description" in fields:
        edit_fields["description"] = fields["description"]
    if "priority" in fields:
        edit_fields["priority"] = _resolve_priority(fields["priority"])
    if "assignee" in fields:
        edit_fields["assignee"] = _extract_name(fields["assignee"])

    written: list[str] = []
    if edit_fields:
        path = _write_event_file(tracker_dir, local_id, "EDIT", {"fields": edit_fields})
        written.append(str(path))

    if "status" in fields:
        local_status = _jira_status_to_local(_extract_name(fields["status"]))
        # current_status is the PREVIOUS state (matched against state["status"]
        # by the reducer for fork detection — see
        # ticket_reducer/_processors.py:process_status).
        # Read the latest STATUS event from the ticket dir to obtain it.
        previous_status = _read_latest_status(tracker_dir, local_id)
        path = _write_event_file(
            tracker_dir,
            local_id,
            "STATUS",
            {"status": local_status, "current_status": previous_status},
        )
        written.append(str(path))

    return ApplyResult(
        mutation.direction,
        mutation.action,
        {"local_id": local_id, "events": written},
    )


def _apply_inbound_delete(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Handle one of four probe-outcome branches when a Jira issue has
    disappeared from the working set.

    Branches (selected via ``mutation.payload['probe_outcome']``):
      * ``hard_delete``  — preserve the local content + emit a follow-on
        ``(outbound, create_after_hard_delete)`` mutation so reconcile_once
        re-creates the Jira side on the next applier pass.
      * ``redirect``     — rename the local jira-dig-NNN ticket directory to
        the new key supplied under ``new_jira_key``.
      * ``out_of_window``— write a COMMENT event noting the Jira issue is
        closed and aged out of the working set (no local mutation otherwise).
      * ``trash``        — write a COMMENT event noting recoverable trash state.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)

    payload = dict(mutation.payload or {})
    branch = payload.get("probe_outcome", "out_of_window")
    target = mutation.target
    local_id = target if target.startswith("jira-") else _jira_key_to_local_id(target)
    tracker_dir = _resolve_tracker_dir(repo_root)
    result_payload: dict[str, Any] = {"branch": branch, "local_id": local_id}

    if branch == "hard_delete":
        _write_event_file(
            tracker_dir,
            local_id,
            "COMMENT",
            {
                "comment": (
                    f"reconciler: Jira issue {target} hard-deleted; local "
                    "content preserved. Outbound re-create follow-on emitted."
                )
            },
        )
        follow_on = {
            "direction": "outbound",
            "action": "create_after_hard_delete",
            "target": target,
            "local_id": local_id,
        }
        result_payload["follow_on"] = follow_on
        # TODO(epic-3e36): wire the follow-on mutation into reconcile_once so
        # the outbound re-create runs in the same pass. Tracked separately.
    elif branch == "redirect":
        new_key = payload.get("new_jira_key", "")
        new_local_id = (
            _jira_key_to_local_id(new_key) if new_key else local_id + "-redirected"
        )
        src = tracker_dir / local_id
        dst = tracker_dir / new_local_id
        # Collision protection (PR #375 review thread 3307104042): when both
        # src and dst already exist on disk (prior failed pass, or the
        # destination key was imported by another path) we cannot silently
        # skip the rename — that leaves the tracker holding two ticket dirs
        # for the same logical ticket. Raise so the operator can reconcile.
        if src.exists() and dst.exists():
            raise FileExistsError(
                f"inbound delete redirect: refusing to rename {src} -> {dst} "
                f"because destination already exists (target={target}, "
                f"new_jira_key={new_key!r})"
            )
        if src.exists() and not dst.exists():
            src.rename(dst)
        # Write a comment noting the redirect on the destination directory.
        _write_event_file(
            tracker_dir,
            new_local_id,
            "COMMENT",
            {"comment": f"reconciler: redirected from {target} -> {new_key}"},
        )
        result_payload["new_local_id"] = new_local_id
    elif branch == "out_of_window":
        _write_event_file(
            tracker_dir,
            local_id,
            "COMMENT",
            {
                "comment": (
                    f"reconciler: Jira issue {target} is closed and has aged "
                    "out of the working window."
                )
            },
        )
    elif branch == "trash":
        _write_event_file(
            tracker_dir,
            local_id,
            "COMMENT",
            {
                "comment": (
                    f"reconciler: Jira issue {target} entered recoverable trash state."
                )
            },
        )
    else:
        # Unknown branch: record observable evidence; do not raise so the pass
        # converges. The structural test enforces real-body coverage.
        _write_event_file(
            tracker_dir,
            local_id,
            "COMMENT",
            {"comment": f"reconciler: unknown probe_outcome={branch!r}"},
        )

    return ApplyResult(mutation.direction, mutation.action, result_payload)


def _apply_inbound_probe(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Inbound probe leaf: probe execution lives in reconcile.route_inbound_probe.

    The leaf itself is a marker — the probe classification and follow-on
    generation happen upstream of applier dispatch. We still write an audit
    comment so the dispatch path is observable in the local tracker when a
    probe leaf is invoked directly.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    target = mutation.target
    local_id = target if target.startswith("jira-") else _jira_key_to_local_id(target)
    tracker_dir = _resolve_tracker_dir(repo_root)
    ticket_dir = tracker_dir / local_id
    if ticket_dir.exists():
        _write_event_file(
            tracker_dir,
            local_id,
            "COMMENT",
            {"comment": f"reconciler: inbound probe acknowledged for {target}"},
        )
    return ApplyResult(
        mutation.direction, mutation.action, {"local_id": local_id, "probed": target}
    )


def _apply_inbound_clean_label(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Remove dso-id-* labels from a Jira issue.

    Inbound-only leaf: invoked when the differ has detected stale or duplicated
    `dso-id-*` labels on the Jira side that need to be removed. The mutation
    payload carries the labels to remove under ``labels_to_remove``; only labels
    that match the ``dso-id-*`` pattern are removed (defensive filter against a
    misshapen payload). All client calls go through :func:`_call_with_retry`
    so transient 5xx/429/timeout failures retry with backoff.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    if client is None:
        # Stub path: preserved for tests that don't exercise the I/O leaf.
        return ApplyResult(mutation.direction, mutation.action, {})
    labels = mutation.payload.get("labels_to_remove") or []
    removed: list[str] = []
    for label in labels:
        # Defensive: only remove labels matching the dso-id-* pattern.
        if not isinstance(label, str) or not label.startswith("dso-id-"):
            continue
        _call_with_retry(client.remove_label, mutation.target, label)
        removed.append(label)
    return ApplyResult(mutation.direction, mutation.action, {"removed": removed})


def _apply_inbound_repair_property(
    mutation, *, client=None, repo_root=None
) -> ApplyResult:
    """Repair a missing ``dso_local_id`` entity property on a Jira issue.

    Delegates to the existing :func:`inbound_repair_property` implementation
    (kept under its legacy name for back-compat with existing tests). Wraps
    the outcome dict into an ``ApplyResult`` so it routes cleanly through the
    typed-mutation dispatch table.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    if client is None:
        # Stub path: preserved for tests that don't exercise the I/O leaf.
        return ApplyResult(mutation.direction, mutation.action, {})
    outcome = inbound_repair_property(mutation, client)
    return ApplyResult(mutation.direction, mutation.action, outcome)


def _file_conflict_bug_ticket(
    cli_path: Path, title: str, description: str, parent_id: str
) -> str:
    """Spawn the ticket CLI as a subprocess to file a bug ticket.

    Returns the canonical bug id on success, '' otherwise. Isolated as its
    own function so tests can monkeypatch this single seam without touching
    the broader subprocess module (which is used by _concurrency).
    """
    import subprocess

    if not cli_path.exists():
        return ""
    cmd: list[str] = [
        str(cli_path),
        "ticket",
        "create",
        "bug",
        title,
        "-d",
        description,
    ]
    if parent_id:
        cmd.extend(["--parent", parent_id])
    try:
        res = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if res.returncode != 0:
        return ""
    lines = [ln for ln in res.stdout.splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def _apply_inbound_conflict(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """File a bug ticket for an unresolved (local, Jira) conflict and emit a
    ``suppress_pair`` follow-on so reconcile_once drops further mutations for
    the same pair in this pass.

    Filing uses the local ``.claude/scripts/dso ticket create bug`` shim via
    subprocess to avoid a hard import dependency on the ticket-CLI Python
    package. When the CLI is unavailable (e.g. inside a fixture worktree),
    the follow-on is still emitted so suppression works.
    """
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)

    payload = dict(mutation.payload or {})
    jira_key = mutation.target
    local_id = payload.get("local_id", "")
    reason = payload.get("reason", "unspecified")
    parent_id = payload.get("parent_id") or os.environ.get(
        "DSO_RECONCILER_CONFLICT_PARENT_ID", ""
    )
    title = f"[Reconciler conflict]: pair ({local_id!r}, {jira_key!r}) -> {reason}"
    description = (
        f"Reconciler detected a conflict on (local_id={local_id!r}, "
        f"jira_key={jira_key!r}).\n\n"
        f"Reason: {reason}\n\n"
        "## Expected Behavior\n"
        "Conflict is resolved or suppressed before the next reconciler pass.\n\n"
        "## Actual Behavior\n"
        f"Conflict surfaced during applier dispatch with reason={reason!r}."
    )

    cli_path = Path(__file__).parents[4] / ".claude" / "scripts" / "dso"
    bug_id = _file_conflict_bug_ticket(cli_path, title, description, parent_id)

    follow_on = {
        "kind": "suppress_pair",
        "local_id": local_id,
        "jira_key": jira_key,
    }
    return ApplyResult(
        mutation.direction,
        mutation.action,
        {"bug_id": bug_id, "follow_on": follow_on},
    )


def _build_leaves() -> dict[tuple[Any, Any], Callable[..., ApplyResult]]:
    """Build the _LEAVES registry.

    Built lazily-but-eagerly (at module import) by walking mutation._VALID_COMBINATIONS
    and binding the leaf handler for each pair. Only pairs in _VALID_COMBINATIONS
    are registered — invalid pairs (e.g. outbound + clean_label) are not present
    by construction.
    """
    mut_mod = _load_mutation_module()
    D = mut_mod.MutationDirection
    A = mut_mod.MutationAction
    handlers: dict[tuple[Any, Any], Callable[..., ApplyResult]] = {
        (D.outbound, A.create): _apply_outbound_create,
        (D.outbound, A.update): _apply_outbound_update,
        (D.outbound, A.delete): _apply_outbound_delete,
        (D.outbound, A.probe): _apply_outbound_probe,
        (D.outbound, A.conflict): _apply_outbound_conflict,
        (D.inbound, A.create): _apply_inbound_create,
        (D.inbound, A.update): _apply_inbound_update,
        (D.inbound, A.delete): _apply_inbound_delete,
        (D.inbound, A.probe): _apply_inbound_probe,
        (D.inbound, A.clean_label): _apply_inbound_clean_label,
        (D.inbound, A.repair_property): _apply_inbound_repair_property,
        (D.inbound, A.conflict): _apply_inbound_conflict,
    }
    # Filter to only valid combinations — single source of truth is mutation.py.
    valid = mut_mod._VALID_COMBINATIONS
    return {k: v for k, v in handlers.items() if k in valid}


# The dispatch registry. Keys are (MutationDirection, MutationAction) tuples;
# values are leaf handler callables of shape (mutation, *, client=None) -> ApplyResult.
_LEAVES: dict[tuple[Any, Any], Callable[..., ApplyResult]] = _build_leaves()


# ---------------------------------------------------------------------------
# dso-id label write authorization contract
# ---------------------------------------------------------------------------

# Justification for the F841 suppression below: this constant is read by
# tests/unit/dso_reconciler/test_errors.py::test_authorized_writers_docstring
# _documents_full_contract via getattr — static analyzers cannot trace the
# usage. Do NOT remove; it is the contract artifact for story 4496 dd-1.
_AUTHORIZED_DSO_ID_LABEL_WRITERS_DOC: str = """  # noqa: F841
dso-id label write authorization contract for applier.py
=========================================================

The applier dispatches mutations through exactly 9 leaf handlers, listed below
with their authorization status for dso-id label mutations:

  1. outbound_create       — AUTHORIZED for {create}: adds "dso-id:<local_id>"
                             label when a new Jira issue is created outbound.
  2. outbound_update       — UNAUTHORIZED for dso-id label mutations.
  3. outbound_delete       — UNAUTHORIZED for dso-id label mutations.
  4. outbound_probe        — UNAUTHORIZED for dso-id label mutations.
  5. outbound_conflict     — UNAUTHORIZED for dso-id label mutations.
  6. inbound_create        — AUTHORIZED for {create}: adds "dso-id:<local_id>"
                             label when a new local ticket is created inbound
                             (dedup write-back so the differ recognizes the
                             issue as mirrored on subsequent passes).
  7. inbound_update        — UNAUTHORIZED for dso-id label mutations.
  8. inbound_clean_label   — AUTHORIZED for {delete}: removes stale or
                             duplicated "dso-id-*" labels from the Jira side.
  9. inbound_repair_property — UNAUTHORIZED for dso-id label mutations.
                              This leaf writes the dso_local_id entity PROPERTY
                              FIELD via set_issue_property(), NOT the label.

Only inbound_clean_label (delete), outbound_create (create), and
inbound_create (create) may emit dso-id label mutations. Any other leaf that emits such a mutation is a bug
and should raise DsoIdLabelWriteError from _errors.py.

conflict_resolver per-element provenance MUST skip dso-id fields. The
conflict_resolver must not write, modify, or emit dso-id label mutations;
dso-id is the identity primitive and its provenance is governed solely by the
two authorized leaves above, not by the per-field provenance resolution path.

inbound_repair_property writes the dso_local_id property field (entity
properties, not labels). It MUST NOT touch the label surface.
"""

_AUTHORIZED_DSO_ID_LABEL_WRITERS: frozenset[str] = frozenset(
    {"inbound_clean_label", "outbound_create", "inbound_create"}
)
"""Leaf names authorized to emit dso-id label mutations (see _AUTHORIZED_DSO_ID_LABEL_WRITERS_DOC)."""

# Per-leaf authorized-action map: enforced by _audit_dso_id_label_writes.
# Each authorized leaf is permitted ONLY the action(s) listed here; any other
# action on a dso-id-* label by the same leaf raises DsoIdLabelWriteError. The
# pair set is the single source of truth referenced by
# _AUTHORIZED_DSO_ID_LABEL_WRITERS_DOC above.
_AUTHORIZED_DSO_ID_LABEL_ACTIONS: dict[str, frozenset[str]] = {
    "outbound_create": frozenset({"create"}),
    "inbound_create": frozenset({"create"}),
    "inbound_clean_label": frozenset({"delete"}),
}

# ---------------------------------------------------------------------------
# dso-id label write guard
#
# _audit_dso_id_label_writes is called after every leaf returns its mutation
# list (or before dispatching the typed-mutation leaf) to ensure no unauthorized
# leaf emits a dso-id-* label mutation.
#
# Guard mode is controlled by DSO_DSO_ID_GUARD_MODE (env) or dso_id_guard_mode
# (dso-config.conf key). Precedence: env > config > default ('raise').
# ---------------------------------------------------------------------------


def _get_dso_id_guard_mode_from_config() -> str | None:
    """Read dso_id_guard_mode from dso-config.conf, if present.

    Returns the value string (e.g. 'raise', 'warn') or None when the key
    is absent or the file cannot be read.

    Resolution order for the guard mode (env wins):
      1. os.environ['DSO_DSO_ID_GUARD_MODE']  — checked in _audit_dso_id_label_writes
      2. This function (dso-config.conf fallback)
      3. Default: 'raise'
    """
    try:
        config_path = Path(__file__).parents[4] / ".claude" / "dso-config.conf"
        if not config_path.exists():
            return None
        for line in config_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("dso_id_guard_mode"):
                parts = line.split("=", 1)
                if len(parts) == 2:
                    return parts[1].strip().strip('"').strip("'")
    except OSError:
        # Best-effort config read: filesystem-level failures (permission denied,
        # missing parent dir on race, etc.) fall through to the default 'raise'
        # guard mode. Programming errors (AttributeError, TypeError) intentionally
        # propagate so they surface during test runs.
        return None
    return None


def _is_dso_id_label_write_mutation(mutation) -> bool:
    """Return True when *mutation* represents a dso-id-* label write.

    Checks two shapes:
    - String payload (direct audit call): mutation.target == 'label' AND
      mutation.payload.startswith('dso-id-') AND action in {create,update,delete}.
    - Dict payload (full Mutation from apply()): payload contains 'target'=='label'
      AND 'label' value starts with 'dso-id-' AND action in {create,update,delete}.
    """
    action = str(getattr(mutation, "action", ""))
    if action not in {"create", "update", "delete"}:
        return False
    payload = getattr(mutation, "payload", None)
    if isinstance(payload, str):
        # String payload: check target field and payload value
        target = getattr(mutation, "target", "")
        return target == "label" and payload.startswith("dso-id-")
    elif isinstance(payload, dict):
        # Dict payload: check embedded 'target'=='label' and 'label' value
        embedded_target = payload.get("target", "")
        label_val = payload.get("label", "")
        if (
            embedded_target == "label"
            and isinstance(label_val, str)
            and label_val.startswith("dso-id-")
        ):
            return True
    return False


def _audit_dso_id_label_writes(leaf_name: str, mutations: list) -> None:
    """Guard: raise (or warn) when an unauthorized leaf emits a dso-id-* label mutation.

    Called before leaf dispatch (`_apply_typed`) AND on each leaf invocation in
    the legacy batch path (`_apply_batch`) to enforce the two-authorized-leaves
    contract documented in `_AUTHORIZED_DSO_ID_LABEL_WRITERS_DOC`.

    Per-action enforcement (wired via `_AUTHORIZED_DSO_ID_LABEL_ACTIONS`):
      - When `leaf_name` is in `_AUTHORIZED_DSO_ID_LABEL_WRITERS` but emits an
        action OUTSIDE its permitted action set (e.g., outbound_create
        attempting a `delete` on a dso-id label), the guard still raises. The
        contract is per-action; defeating it would leave a security gap by
        allowing an authorized leaf to perform any action.

    Guard mode (DSO_DSO_ID_GUARD_MODE env var, dso-config.conf key dso_id_guard_mode,
    default 'raise'):
      - 'raise': DsoIdLabelWriteError raised on violation (default, production-safe).
      - 'warn': WARNING logged with tag DSO_ID_GUARD; no exception raised (staged rollout).

    Precedence: env var > dso-config.conf key > default 'raise'.
    """
    is_authorized_leaf = leaf_name in _AUTHORIZED_DSO_ID_LABEL_WRITERS
    allowed_actions = _AUTHORIZED_DSO_ID_LABEL_ACTIONS.get(leaf_name, frozenset())

    offending = None
    offending_payload = None
    offending_action = None
    for mutation in mutations:
        if not _is_dso_id_label_write_mutation(mutation):
            continue
        action_str = str(getattr(mutation, "action", ""))
        if is_authorized_leaf and action_str in allowed_actions:
            # Permitted (leaf, action) pair — skip without raising.
            continue
        offending = mutation
        offending_action = action_str
        # Extract the label payload for the error message
        payload = getattr(mutation, "payload", "")
        if isinstance(payload, str):
            offending_payload = payload
        elif isinstance(payload, dict):
            offending_payload = payload.get("label", str(payload))
        else:
            offending_payload = str(payload)
        break

    if offending is None:
        return

    # Determine guard mode: env > config > default 'raise'
    guard_mode = os.environ.get("DSO_DSO_ID_GUARD_MODE")
    if guard_mode is None:
        guard_mode = _get_dso_id_guard_mode_from_config()
    if guard_mode is None:
        guard_mode = "raise"

    msg = (
        f"DSO_ID_GUARD: unauthorized dso-id label write from leaf '{leaf_name}' "
        f"(action={offending_action!r}); offending payload: {offending_payload!r}"
    )

    if guard_mode == "warn":
        logger.warning(msg)
        return

    errs = _load_errors_module()
    raise errs.DsoIdLabelWriteError(msg)


class _BatchAuditView:
    """Adapter exposing a legacy dict-shaped batch mutation to the audit guard.

    The audit (`_is_dso_id_label_write_mutation`) expects an object with
    ``target``, ``payload`` (str OR dict), and ``action`` attributes. Legacy
    batch mutations are dicts of shape ``{"action": ..., "key": ..., "fields":
    {"labels": [...], ...}}`` — this view surfaces any dso-id-* label values
    sitting under ``fields["labels"]`` as a synthetic label-write mutation so
    the guard fires on unauthorized batch paths (e.g., an outbound_update
    trying to push a dso-id-* label).

    ``target`` is set to 'label' iff the batch mutation includes a dso-id-*
    label in its fields; otherwise an empty string makes the audit pass-through.
    """

    __slots__ = ("target", "payload", "action")

    def __init__(self, batch_mutation: dict) -> None:
        self.action = batch_mutation.get("action", "")
        fields = batch_mutation.get("fields") or {}
        labels = fields.get("labels") if isinstance(fields, dict) else None
        dso_label = None
        if isinstance(labels, (list, tuple)):
            for lbl in labels:
                if isinstance(lbl, str) and lbl.startswith("dso-id-"):
                    dso_label = lbl
                    break
        if dso_label is not None:
            self.target = "label"
            self.payload = dso_label
        else:
            # Synthesise an explicit non-label target so the guard's
            # _is_dso_id_label_write_mutation returns False on benign batches.
            self.target = ""
            self.payload = ""


# Mapping from (MutationDirection.value, MutationAction.value) → canonical leaf name.
# Mirrors the _LEAVES dispatch table; used by _apply_typed to derive leaf_name for
# the audit without needing to inspect function names.
_LEAF_NAMES: dict[tuple[str, str], str] = {
    ("outbound", "create"): "outbound_create",
    ("outbound", "update"): "outbound_update",
    ("outbound", "delete"): "outbound_delete",
    ("outbound", "probe"): "outbound_probe",
    ("outbound", "conflict"): "outbound_conflict",
    ("inbound", "create"): "inbound_create",
    ("inbound", "update"): "inbound_update",
    ("inbound", "delete"): "inbound_delete",
    ("inbound", "probe"): "inbound_probe",
    ("inbound", "clean_label"): "inbound_clean_label",
    ("inbound", "repair_property"): "inbound_repair_property",
    ("inbound", "conflict"): "inbound_conflict",
}


def _apply_typed(mutation, *, client=None, repo_root=None) -> ApplyResult:
    """Typed-mutation dispatch via _LEAVES.

    Looks up (mutation.direction, mutation.action) in _LEAVES and invokes the
    handler. Raises UnknownActionError with zero side-effects (no client calls,
    no I/O) if the pair is not registered.

    Calls _audit_dso_id_label_writes BEFORE invoking the leaf so that any
    unauthorized dso-id label mutation is blocked prior to side-effects.
    """
    key = (mutation.direction, mutation.action)
    handler = _LEAVES.get(key)
    if handler is None:
        errs = _load_errors_module()
        raise errs.UnknownActionError(
            f"unknown (direction={mutation.direction.value!s}, "
            f"action={mutation.action.value!s})"
        )
    # Audit: derive leaf_name from the (direction, action) pair and run the
    # dso-id label write guard before any leaf side-effect occurs.
    leaf_name = _LEAF_NAMES.get((mutation.direction.value, mutation.action.value), "")
    _audit_dso_id_label_writes(leaf_name, [mutation])
    # All inbound leaves accept repo_root; outbound leaves now do too. Pass it
    # uniformly so the leaves can write to the local tracker when applicable.
    # Inspect the handler signature once to decide whether to pass repo_root,
    # rather than catching a broad TypeError (which would silently swallow
    # genuine TypeErrors raised from inside the leaf body — bug surfaced in
    # PR #375 review thread 3306949603).
    import inspect as _inspect

    try:
        sig = _inspect.signature(handler)
        accepts_repo_root = "repo_root" in sig.parameters or any(
            p.kind is _inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()
        )
    except (TypeError, ValueError):
        # Builtins / C-extensions don't expose signatures: fall back to passing
        # repo_root (legacy behaviour).
        accepts_repo_root = True

    if accepts_repo_root:
        return handler(mutation, client=client, repo_root=repo_root)
    return handler(mutation, client=client)


# Exit code signalling that the caller should reschedule this pass.
# Distinct from 1 (error) and 0 (success).  Chosen to be outside the
# range used by common POSIX utilities so it remains unambiguous.
EXIT_RESCHEDULE: int = 75


class RescheduleError(Exception):
    """Raised by apply() when rebase_retry exhausts all write attempts.

    Carries the attempt count and the last error message so the caller can
    emit a structured health event before exiting with EXIT_RESCHEDULE.
    No retry-counter file is written to disk; the next pass starts fresh.
    """

    def __init__(self, attempt_count: int, last_error: str) -> None:
        super().__init__(
            f"reject_and_reschedule after {attempt_count} attempt(s): {last_error}"
        )
        self.attempt_count = attempt_count
        self.last_error = last_error


class JiraAPIError(Exception):
    """Exception raised by AcliClient stubs to simulate Jira HTTP error responses."""

    def __init__(self, message: str, status_code: int) -> None:
        super().__init__(message)
        self.status_code = status_code


class RetryExhaustedError(Exception):
    """Raised when _call_with_retry exhausts all retry attempts."""


def _call_with_retry(fn, *args, timeout_s: int = 30, max_retries: int = 3, **kwargs):
    """Call fn(*args, **kwargs) with exponential backoff on retryable failures.

    Retryable: TimeoutError, JiraAPIError with status 5xx, JiraAPIError with status 429.
    Non-retryable: JiraAPIError with 4xx (except 429) — re-raised immediately.
    On exhaustion of max_retries, raises RetryExhaustedError.

    Args:
        fn:          Callable to invoke.
        *args:       Positional arguments forwarded to fn.
        timeout_s:   Per-call timeout in seconds (currently advisory for stub-based callers).
        max_retries: Maximum number of retry attempts after the first failure.
        **kwargs:    Keyword arguments forwarded to fn.

    Returns:
        The return value of fn on success.

    Raises:
        RetryExhaustedError: When all retry attempts are exhausted.
        JiraAPIError:        Immediately, for non-retryable 4xx (except 429) errors.
    """
    delays = [1, 2, 4]
    last_exc: Exception | None = None

    for attempt in range(max_retries + 1):
        try:
            return fn(*args, **kwargs)
        except JiraAPIError as exc:
            # 429 and 5xx are retryable; all other 4xx fail fast
            if exc.status_code != 429 and 400 <= exc.status_code < 500:
                raise
            last_exc = exc
        except TimeoutError as exc:
            last_exc = exc

        if attempt < max_retries:
            delay = delays[min(attempt, len(delays) - 1)]
            time.sleep(delay)

    raise RetryExhaustedError(str(last_exc))


def _load_acli():
    """Load acli-integration module via importlib."""
    acli_path = Path(__file__).parent.parent / "acli-integration.py"
    spec = importlib.util.spec_from_file_location("acli_integration", acli_path)
    if spec is None:
        raise FileNotFoundError(f"acli-integration.py not found at {acli_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("acli_integration", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


class HeadDriftError(Exception):
    """Raised when the tickets-branch HEAD changes mid-pass, indicating concurrent write."""


def _load_concurrency():
    """Load _concurrency module via importlib."""
    concurrency_path = Path(__file__).parent / "_concurrency.py"
    spec = importlib.util.spec_from_file_location("_concurrency", concurrency_path)
    if spec is None:
        raise FileNotFoundError(f"_concurrency.py not found at {concurrency_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("_concurrency", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _write_pass_record(repo_root: Path, pass_id: str, mutation_count: int) -> None:
    """Write a pass completion record to bridge_state/snapshots/<pass_id>.pass_record.json.

    This simulates the tickets-branch write.  In a full implementation this
    would commit the record to the tickets orphan branch.

    Args:
        repo_root:      Repository root directory.
        pass_id:        Unique identifier for this reconciliation pass.
        mutation_count: Number of mutations processed in this pass.
    """
    snapshots_dir = repo_root / "bridge_state" / "snapshots"
    snapshots_dir.mkdir(parents=True, exist_ok=True)
    record_path = snapshots_dir / f"{pass_id}.pass_record.json"
    record = {
        "pass_id": pass_id,
        "mutation_count": mutation_count,
        "status": "complete",
    }
    record_path.write_text(json.dumps(record, indent=2))


def _load_conflict_resolver():
    """Load conflict_resolver module via importlib."""
    resolver_path = Path(__file__).parent / "conflict_resolver.py"
    spec = importlib.util.spec_from_file_location(
        "dso_reconciler_conflict_resolver", resolver_path
    )
    if spec is None:
        raise FileNotFoundError(f"conflict_resolver.py not found at {resolver_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("dso_reconciler_conflict_resolver", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _load_mapping(mapping_path: Path) -> dict:
    """Load mapping.json, returning an empty dict if missing or corrupt.

    F10: when the file parses but contains a non-dict (e.g. a list or string
    from a corrupt write), downstream code that calls ``data[jira_key] = ...``
    would raise TypeError. Guard by returning ``{}`` for any non-dict value;
    subsequent writes will overwrite the corrupt file with a clean dict.
    """
    if mapping_path.exists():
        try:
            data = json.loads(mapping_path.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
        if not isinstance(data, dict):
            return {}
        return data
    return {}


def _write_mapping_json_atomic(mapping_path: Path, data: dict) -> None:
    """Write data to mapping_path atomically using temp-file + os.replace.

    Args:
        mapping_path: Full path to mapping.json.
        data:         Complete dict to serialize.
    """
    mapping_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=mapping_path.parent, suffix=".tmp", prefix="mapping_"
    )
    try:
        with os.fdopen(tmp_fd, "w") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp_path, mapping_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass  # cleanup is best-effort; preserve and re-raise original write error
        raise


def _persist_field_provenance(
    mapping_path: Path,
    jira_key: str,
    field_name: str,
    field_value,
) -> None:
    """Persist field provenance for a set-valued field to mapping.json.

    Reads the current mapping.json, updates
    ``mapping[jira_key]["field_provenance"][field_name]`` with a provenance_record
    list derived from field_value, then writes back atomically.

    Args:
        mapping_path: Full path to mapping.json.
        jira_key:     Jira issue key (top-level key in mapping).
        field_name:   Name of the set-valued field (e.g., "labels").
        field_value:  The field value (list) from the mutation.
    """
    # Build the provenance_record list from the field value
    if isinstance(field_value, list):
        provenance_record = list(field_value)
    elif field_value is not None:
        provenance_record = [field_value]
    else:
        provenance_record = []

    data = _load_mapping(mapping_path)

    # Ensure nested structure exists
    if jira_key not in data:
        data[jira_key] = {}
    if not isinstance(data[jira_key], dict):
        data[jira_key] = {}
    if "field_provenance" not in data[jira_key]:
        data[jira_key]["field_provenance"] = {}

    data[jira_key]["field_provenance"][field_name] = provenance_record

    _write_mapping_json_atomic(mapping_path, data)


def _write_mapping_atomic(mapping_path: Path, local_id: str, jira_key: str) -> None:
    """Atomically update mapping.json with local_id -> jira_key entry.

    Uses a temp-file + os.replace pattern so readers never see a partial write.

    Args:
        mapping_path: Full path to mapping.json.
        local_id:     Local ticket ID (key to set).
        jira_key:     Jira issue key (value to set).
    """
    mapping_path.parent.mkdir(parents=True, exist_ok=True)

    # Load existing mapping (tolerate missing file)
    existing = _load_mapping(mapping_path)
    existing[local_id] = jira_key

    _write_mapping_json_atomic(mapping_path, existing)


def create_one(
    mutation: dict,
    client,
    rest_calls: int = 0,
    deferred_creates: list | None = None,
    events_list: list | None = None,
    repo_root: Path | None = None,
    binding_store=None,
) -> dict | None:
    """Create a Jira issue from the mutation's fields, with budget guard and JQL dedup.

    Budget guard: if rest_calls >= 200, appends mutation to deferred_creates and
    returns None without issuing any REST calls.

    JQL dedup: searches for an existing issue with label 'dso-id:<local_id>' before
    creating. On hit, skips create_issue(), writes mapping.json atomically, appends a
    dedup-create-skipped event to events_list, and returns a dedup sentinel.
    On miss, proceeds with create_issue().

    Args:
        mutation:         Mutation dict with at least "fields" and optionally "local_id".
        client:           AcliClient instance.
        rest_calls:       Number of REST calls already issued in this pass.
        deferred_creates: List to append deferred mutations to (budget guard).
        events_list:      List to append structured events to (dedup hit events).
        repo_root:        Repository root for resolving bridge_state/mapping.json.
                          Defaults to four levels above this file when None.

    Returns:
        The client.create_issue() result on miss, a dedup sentinel dict on hit,
        or None when the mutation is budget-deferred.
    """
    # Budget guard: defer without any REST call when at or over the limit
    if rest_calls >= 200:
        if deferred_creates is not None:
            deferred_creates.append(mutation)
        return None

    local_id = mutation.get("local_id", "")
    jql = f'labels = "dso-id:{local_id}"'
    hits = client.search_issues(jql)

    if hits:
        hit_key = hits[0].get("key", "")

        # Persist local_id -> jira_key in mapping.json atomically
        if repo_root is None:
            repo_root = Path(__file__).parents[4]
        mapping_path = repo_root / "bridge_state" / "mapping.json"
        _write_mapping_atomic(mapping_path, local_id, hit_key)

        # Emit structured event into the caller's events list
        if events_list is not None:
            events_list.append(
                {
                    "event": "dedup-create-skipped",
                    "local_id": local_id,
                    "jira_key": hit_key,
                }
            )

        if binding_store is not None and local_id and hit_key:
            binding_store.bind_confirm(local_id, hit_key)
        return {"status": "dedup-create-skipped", "key": hit_key}

    # Translate differ-emitted Jira snapshot field names (summary, status,
    # issuetype) into the bridge schema (title, ticket_type) that
    # AcliClient.create_issue requires. Without this translation, create_issue
    # raises ValueError("title/summary is empty") because the differ never
    # emits a 'title' key. The mapping is conservative — only the two fields
    # AcliClient inspects are remapped; everything else passes through.
    _raw_fields = mutation.get("fields", {})
    _ticket_data = dict(_raw_fields)
    if "title" not in _ticket_data:
        # 'summary' is Jira's canonical field for the human-readable headline;
        # AcliClient.create_issue uses 'title' as the bridge-side equivalent.
        _ticket_data["title"] = _ticket_data.get("summary", "")
    if "ticket_type" not in _ticket_data:
        _issuetype = _ticket_data.get("issuetype")
        if isinstance(_issuetype, dict):
            _ticket_data["ticket_type"] = _issuetype.get("name", "Task")
        elif isinstance(_issuetype, str):
            _ticket_data["ticket_type"] = _issuetype
        else:
            _ticket_data["ticket_type"] = "Task"
    result = _call_with_retry(client.create_issue, _ticket_data)

    # Write identity markers so the issue can be re-discovered by dedup JQL
    # and by inbound consumers that inspect entity properties.
    jira_key = result.get("key", "") if isinstance(result, dict) else ""
    if jira_key:
        try:
            # Wrap identity writes in _call_with_retry so transient 5xx/429
            # absorb the same retry budget as create_issue above. Without this,
            # a single transient failure here triggers the unnecessary rollback
            # branch (delete_issue + BRIDGE_ALERT) even though the underlying
            # condition would have cleared on retry.
            _call_with_retry(client.add_label, jira_key, f"dso-id:{local_id}")
            _call_with_retry(
                client.set_entity_property, jira_key, "dso_local_id", local_id
            )
            if binding_store is not None and local_id:
                binding_store.bind_confirm(local_id, jira_key)
        except Exception as write_err:
            try:
                client.delete_issue(jira_key)
            except Exception:
                pass  # rollback failure must not mask original error
            # Emit BRIDGE_ALERT for identity-write rollback so the event is
            # surfaced in the tickets-tracker for observability.  # tickets-boundary-ok
            try:
                import uuid as _uuid
                import time as _time
                import json as _json

                _alert_root = (
                    repo_root or Path(__file__).parents[4]
                ) / ".tickets-tracker"
                # F7: defensive guard — if local_id is falsy the alert directory
                # would resolve to .tickets-tracker root and pollute it. Prefer
                # the jira_key, falling back to a uuid so the alert always lands
                # under a non-root subdirectory.
                _alert_dir_key = local_id or jira_key or f"unknown-{_uuid.uuid4()}"
                _ticket_dir = _alert_root / _alert_dir_key
                _ticket_dir.mkdir(parents=True, exist_ok=True)
                _ts = _time.time_ns()
                _alert_uuid = str(_uuid.uuid4())
                _alert_path = _ticket_dir / f"{_ts}-{_alert_uuid}-BRIDGE_ALERT.json"
                _alert_path.write_text(
                    _json.dumps(
                        {
                            "event_type": "BRIDGE_ALERT",
                            "timestamp": _ts,
                            "uuid": _alert_uuid,
                            "ticket_id": local_id,
                            "jira_key": jira_key,
                            "data": {
                                "reason": "identity-write failed after create; Jira issue deleted",
                                "tag": "create-identity-write-failed",
                            },
                        }
                    )
                )
            except Exception:
                pass  # alert write failure must not mask original error
            raise write_err

    return result


def _is_illegal_transition_400(exc: Exception) -> bool:
    """Detect a 400 illegal-transition response from update_issue.

    Jira rejects status transitions that are not allowed from the current
    workflow state with a 400 response whose body mentions 'illegal' or
    'transition'. These are state errors (not transient), so they must not
    be retried.
    """
    code = getattr(exc, "status_code", None) or getattr(exc, "code", None)
    if code != 400:
        return False
    msg = str(exc).lower()
    return "illegal" in msg or "transition" in msg


def update_one(mutation: dict, client) -> dict | None:
    """Update an existing Jira issue from the mutation's key and fields.

    F3: AcliClient.update_issue's real signature is ``update_issue(jira_key, **kwargs)``;
    the field dict must be unpacked into keyword arguments rather than passed
    positionally as a single dict — otherwise Jira receives a TypeError on every
    real update call.

    Comment-fallback on 400 illegal-transition: when Jira rejects a status
    transition because it is not legal from the current workflow state, we do
    NOT retry (zero update_issue retries on 400 — it is a state error, not a
    transient). Instead we post a comment recording the local status change
    so an operator can see the divergence in Jira, and emit a structured log
    record to stderr.
    """
    fields = mutation.get("fields", {})
    if not isinstance(fields, dict):
        fields = {}
    issue_key = mutation.get("key")
    try:
        return _call_with_retry(client.update_issue, issue_key, **fields)
    except JiraAPIError as exc:
        if not _is_illegal_transition_400(exc):
            raise
        new_status = fields.get("status")
        comment = f"local status changed to {new_status}"
        try:
            client.add_comment(issue_key, comment)
        except Exception:
            pass  # secondary failure must not mask the comment-fallback path
        log_entry = json.dumps(
            {
                "action": "comment_fallback",
                "issue_key": issue_key,
                "attempted_status": new_status,
                "reason": "400_illegal_transition",
            }
        )
        print(log_entry, file=sys.stderr)
        return None


def delete_one(mutation: dict, client) -> None:
    """Close a Jira issue by transitioning it to 'Closed'.

    F5: tolerate 404 — when the differ emits a delete it's precisely because
    the issue is no longer present in Jira; the subsequent transition_issue
    call therefore targets a key that may have already been removed. A 404 on
    the transition means the desired post-state ('issue gone') is already
    satisfied, so we treat it as success rather than letting the JiraAPIError
    unwind the entire pass. Other JiraAPIError statuses propagate normally.
    """
    # AcliClient exposes delete_issue (REST DELETE), not transition_issue.
    # The "close = transition to Closed" model belongs to a different bridge
    # surface that we don't use here — delete the Jira issue directly to
    # achieve the desired post-state ("issue gone from Jira").
    try:
        _call_with_retry(client.delete_issue, mutation.get("key"))
    except JiraAPIError as exc:
        if getattr(exc, "status_code", None) == 404:
            return  # already-gone is the goal of a delete mutation
        raise


def inbound_repair_property(mutation, client) -> dict:
    """Repair a missing entity property on a Jira issue.

    Happy path: invokes ``client.set_issue_property(target, 'dso_local_id', local_id)``
    and returns ``{'status': 'ok', 'key': target}``.

    Failure path: when ``set_issue_property`` raises, attempts a follow-on cleanup
    via ``client.remove_label(target, 'dso-id-<local_id>')`` (best-effort — a
    ``remove_label`` exception is captured, NOT raised), and returns an outcome
    dict with ``status='repair_property_failed'`` plus a top-level ``follow_on``
    payload whose ``kind`` is ``'schema_drift_signal'``. The follow-on is the
    signalling seam consumed by reconcile.py; this function MUST NOT import
    invariants directly — preserving the invariants-as-upstream-phase contract
    (see ticket 44e6-4916 AC: "applier.py does NOT import invariants").

    The follow_on field sits at the TOP LEVEL of the outcome dict (not nested
    under 'result'); manifest canonical-form serialization is expected to
    EXCLUDE follow_on fields when computing the content-addressable hash
    (per AC amendment G2 on ticket 44e6-4916).

    Args:
        mutation: Object exposing ``.target`` (Jira issue key) and ``.payload``
                  (mapping with at least a ``'local_id'`` entry).
        client:   AcliClient (or compatible test double) exposing
                  ``set_issue_property`` and ``remove_label``.

    Returns:
        Outcome dict — see status taxonomy above.
    """
    target = mutation.target
    payload = mutation.payload or {}
    local_id = payload.get("local_id", "")

    try:
        client.set_issue_property(target, "dso_local_id", local_id)
        return {"status": "ok", "key": target, "follow_on": None}
    except Exception as exc:
        label_remove_err: Exception | None = None
        try:
            client.remove_label(target, f"dso-id-{local_id}")
        except Exception as e:
            label_remove_err = e

        return {
            "status": "repair_property_failed",
            "key": target,
            "follow_on": {
                "kind": "schema_drift_signal",
                "issue_key": target,
                "reason": f"repair_property_failed: {exc}",
                "label_remove_error": (
                    str(label_remove_err) if label_remove_err is not None else None
                ),
            },
        }


def _handle_failed_write_result(write_result, pass_id: str) -> None:
    """Emit a health event to stderr and raise RescheduleError for a failed write.

    Called when rebase_retry returns ok=False.  The only kind that maps to a
    reschedule exit is 'reject_and_reschedule'; other kinds propagate as-is
    through other code paths (HeadDriftError for drift, exception for error).

    Args:
        write_result: Result(ok=False) returned by rebase_retry.
        pass_id:      Current reconciliation pass identifier (included in the
                      health event for traceability).

    Raises:
        RescheduleError: Always, when this function is called.
    """
    event = write_result.event
    attempt_count = event.attempt if event is not None else 0
    last_error = event.message if event is not None else ""

    health_event = {
        "kind": "reject_and_reschedule",
        "pass_id": pass_id,
        "attempt_count": attempt_count,
        "last_error": last_error,
    }
    print(json.dumps(health_event), file=sys.stderr)
    raise RescheduleError(attempt_count=attempt_count, last_error=last_error)


def _load_mode_module():
    """Lazy-load mode.py under a stable key so MODE_CAPS / Mode are accessible.

    Uses the SAME dotted key as __main__._MODE_KEY so a single module object
    is shared with the entry-point loader; tests that pre-seed sys.modules
    under that key see their stub here too.
    """
    key = "plugins.dso.scripts.dso_reconciler.mode"
    if key in sys.modules:
        return sys.modules[key]
    mode_path = Path(__file__).parent / "mode.py"
    spec = importlib.util.spec_from_file_location(key, mode_path)
    if spec is None or spec.loader is None:
        raise FileNotFoundError(f"mode.py not found at {mode_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[key] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _load_manifest_renderer():
    """Lazy-load manifest_renderer.py."""
    key = "plugins.dso.scripts.dso_reconciler.manifest_renderer"
    if key in sys.modules:
        return sys.modules[key]
    path = Path(__file__).parent / "manifest_renderer.py"
    spec = importlib.util.spec_from_file_location(key, path)
    if spec is None or spec.loader is None:
        raise FileNotFoundError(f"manifest_renderer.py not found at {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[key] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _mode_sort_key(m) -> tuple[str, str, str]:
    """Deterministic ordering key for cap enforcement.

    Outbound creates sort first (priority "0") so they land within the
    bootstrap-strict cap window. Without this, 'inbound' < 'outbound'
    lexicographically causes all cap slots to go to inbound mutations,
    deferring outbound creates indefinitely (bug d5a2-3fc8).
    """
    d = getattr(m, "direction", None)
    a = getattr(m, "action", None)
    t = getattr(m, "target", None)
    if isinstance(m, dict):
        d = d if d is not None else m.get("direction", "")
        a = a if a is not None else m.get("action", "")
        t = t if t is not None else (m.get("key", "") or m.get("target", ""))
    d_str = str(getattr(d, "value", d) or "")
    a_str = str(getattr(a, "value", a) or "")
    if d_str == "outbound" and a_str == "create":
        d_str = "0_outbound_create"
    return (d_str, a_str, str(t or ""))


def apply(
    mutations=None,
    pass_id: str | None = None,
    repo_root: Path | None = None,
    *,
    client=None,
    mode=None,
    binding_store=None,
):
    """Polymorphic dispatch entry point.

    Two call shapes:
      1. Typed single-mutation:  apply(mutation, *, client=None) -> ApplyResult
         When the first positional argument is a Mutation instance, dispatch
         via _LEAVES. Raises UnknownActionError for unregistered pairs (with
         zero side-effects) and DirectionMismatchError if a leaf is invoked
         with a mismatched direction.
      2. Legacy batch:            apply(mutations: list[dict], pass_id, ...) -> Path
         Original manifest-writing batch dispatcher; behavior unchanged.

    Selection is by argument type at the top of the function.
    """
    # Typed-mutation dispatch path: first arg is a Mutation instance.
    # Duck-type rather than isinstance() because mutation.py may be loaded
    # under different module names depending on how the importing test rig
    # set up sys.modules — a strict isinstance() check would silently fall
    # through to the legacy batch path and raise a confusing TypeError.
    mut_mod = _load_mutation_module()
    if isinstance(mutations, mut_mod.Mutation) or (
        type(mutations).__name__ == "Mutation"
        and hasattr(mutations, "direction")
        and hasattr(mutations, "action")
    ):
        return _apply_typed(mutations, client=client, repo_root=repo_root)

    # Legacy batch path requires pass_id.
    if pass_id is None:
        raise TypeError(
            "apply() legacy batch form requires pass_id as the second argument"
        )

    # -------------------------------------------------------------------------
    # Mode-cap enforcement (story 286b).
    #
    # When *mode* is provided, look up the per-mode cap in MODE_CAPS and
    # partition the incoming mutations into (applied, deferred). The applied
    # list is what the direction-aware dispatch loop below actually executes;
    # the deferred list is reported via the mode-specific manifest renderer.
    #
    # Cap semantics:
    #   - cap is None    → uncapped (LIVE): apply all; manifest renderer is
    #                      NOT invoked (LIVE writes no manifest file).
    #   - cap == 0       → DRY_RUN: apply NOTHING (no leaf invoked, no batch
    #                      iteration); manifest still written listing every
    #                      mutation as deferred.
    #   - cap > 0        → BOOTSTRAP_STRICT (10) / BOOTSTRAP_THROTTLE (100):
    #                      sort by (direction, action, target), apply first
    #                      `cap`, defer the rest.
    #
    # When *mode* is None (the call shape used by legacy callers that have not
    # yet been migrated), behaviour is unchanged from before: apply everything,
    # write the legacy flat manifest. This preserves the contract for the wide
    # surface of existing tests under tests/unit/dso_reconciler/.
    # -------------------------------------------------------------------------
    mutations_input = list(mutations or [])
    deferred_for_manifest: list = []
    # Hoist the mode module load to a single call per apply() invocation.
    # Previously _load_mode_module() was called at three sites (cap lookup,
    # DRY_RUN dispatch skip, manifest renderer dispatch); collapsing to one
    # avoids redundant importlib work and a class-identity hazard if the
    # module ever ends up loaded under multiple sys.modules keys mid-call.
    mode_mod = _load_mode_module() if mode is not None else None
    if mode is not None:
        # Validate / coerce mode to a Mode enum member (findings #1/#2).
        # Accepting raw strings would let MODE_CAPS.get() return None for
        # unrecognised values, silently triggering the uncapped LIVE path.
        if isinstance(mode, str):
            mode = mode_mod.Mode.from_str(mode)
        if not isinstance(mode, mode_mod.Mode):
            raise TypeError(
                f"mode must be a Mode enum member or a recognised mode string, "
                f"got {type(mode).__name__}: {mode!r}"
            )
        cap = mode_mod.MODE_CAPS.get(mode)
        # Sort deterministically before applying the cap so the applied /
        # deferred partition is reproducible across passes.
        ordered = sorted(mutations_input, key=_mode_sort_key)
        if cap is None:
            # LIVE: uncapped — proceed with all mutations through the normal
            # dispatch path below. Manifest renderer is skipped post-apply.
            mutations_input = ordered
        elif cap == 0:
            # DRY_RUN: skip the apply loop entirely. Every mutation is deferred.
            deferred_for_manifest = ordered
            mutations_input = []
        else:
            # BOOTSTRAP_STRICT / BOOTSTRAP_THROTTLE: cap then defer remainder.
            mutations_input = ordered[:cap]
            deferred_for_manifest = ordered[cap:]

    # Direction-aware dispatch (defect #8): partition typed Mutations by
    # direction. Inbound Mutations route through _apply_typed per-mutation
    # (so each one fires the inbound leaf from _LEAVES against the local
    # tracker). Outbound Mutations are normalized to dicts and pass through
    # _apply_batch (legacy manifest-writing path). Untyped dict entries
    # default to the outbound batch path — that is the legacy contract.
    #
    # Previously this code path raised TypeError as a fail-closed guard
    # against inbound traffic. The guard was correct in intent — routing
    # inbound through _apply_batch would execute Jira-side outbound
    # handlers — but the production path produces overwhelmingly inbound
    # Mutations on first run (empty local mirror), so the guard blocked
    # every pass. The actual fix is to route inbound through the existing
    # _apply_typed handler (which already covers all (inbound, *) pairs in
    # _LEAVES).
    mutations_list = list(mutations_input)

    def _looks_like_mutation(m) -> bool:
        if isinstance(m, mut_mod.Mutation):
            return True
        return (
            type(m).__name__ == "Mutation"
            and hasattr(m, "direction")
            and hasattr(m, "action")
        )

    def _direction_of(m) -> str:
        d = getattr(m, "direction", None)
        return str(getattr(d, "value", d) or "")

    inbound_typed: list = []
    outbound_or_untyped: list = []
    for m in mutations_list:
        if _looks_like_mutation(m) and _direction_of(m) == "inbound":
            inbound_typed.append(m)
        else:
            outbound_or_untyped.append(m)

    # Inbound: per-mutation dispatch via _apply_typed. Order preserved from
    # the source list so observable behaviour is deterministic.
    #
    # suppress_pair follow-on contract (story bd19-d744-b8c7-4079): when a
    # leaf returns a payload with follow_on={'kind': 'suppress_pair',
    # 'local_id': X, 'jira_key': Y}, all subsequent inbound mutations
    # targeting either X or Y AND all outbound batch entries targeting Y are
    # dropped from this pass so the conflict signal is not stomped by stale
    # follow-up mutations.
    # Suppress-pair index: O(1) lookup. We maintain two sets of canonical
    # identifiers (jira-keys-as-given and local_ids) plus a set of computed
    # local-id forms (jira_key → _jira_key_to_local_id) so the third match-
    # arm (computed-form: target=='DIG-7' suppresses subsequent
    # target=='jira-dig-7') is also O(1). Replaces the prior O(n²) list
    # scan flagged in PR #375 review thread 3306949610.
    suppressed_targets: set[str] = set()
    suppressed_pairs: set[tuple[str, str]] = set()

    def _is_suppressed(target: str) -> bool:
        if not target:
            return False
        return target in suppressed_targets

    def _record_suppression(local_id: str, jira_key: str) -> None:
        suppressed_pairs.add((local_id, jira_key))
        if jira_key:
            suppressed_targets.add(jira_key)
            # Computed-form: a later mutation targeting the local-id form of
            # this jira_key (e.g. 'jira-dig-7' after suppressing 'DIG-7')
            # must also be dropped.
            suppressed_targets.add(_jira_key_to_local_id(jira_key))
        if local_id:
            suppressed_targets.add(local_id)

    # Create an AcliClient for inbound leaves that need to write back to
    # Jira (dso-id label + dso_local_id property). The caller (reconcile_once)
    # does not pass a client — the fetcher creates its own for reading, and
    # the legacy batch path (_apply_batch) creates its own for outbound writes.
    # The inbound dispatch path needs its own for the write-back step.
    if client is None and inbound_typed:
        acli_mod = _load_acli()
        client = acli_mod.AcliClient(
            jira_url=os.environ.get("JIRA_URL", ""),
            user=os.environ.get("JIRA_USER", ""),
            api_token=os.environ.get("JIRA_API_TOKEN", ""),
        )
        logger.info(
            "inbound dispatch: created AcliClient for %d inbound mutations "
            "(JIRA_URL=%s, JIRA_USER=%s)",
            len(inbound_typed),
            os.environ.get("JIRA_URL", "<unset>"),
            os.environ.get("JIRA_USER", "<unset>"),
        )

    for mut in inbound_typed:
        if _is_suppressed(getattr(mut, "target", "")):
            continue
        result = _apply_typed(mut, client=client, repo_root=repo_root)
        follow_on = (
            result.payload.get("follow_on")
            if isinstance(getattr(result, "payload", None), dict)
            else None
        )
        if isinstance(follow_on, dict) and follow_on.get("kind") == "suppress_pair":
            _record_suppression(
                follow_on.get("local_id", ""), follow_on.get("jira_key", "")
            )

    # Outbound (or untyped dict): normalize typed Mutations to dicts so
    # _apply_batch can iterate, then route through the legacy batch path.
    # _apply_batch handles an empty list cleanly (writes an empty manifest)
    # so the all-inbound case still produces a manifest path for the caller.
    outbound_list = [
        _mutation_to_batch_dict(m) if _looks_like_mutation(m) else m
        for m in outbound_or_untyped
    ]
    # Drop any outbound entries whose key matches a suppressed pair.
    if suppressed_pairs:
        outbound_list = [
            d for d in outbound_list if not _is_suppressed(d.get("key", ""))
        ]
    # In DRY_RUN, skip the legacy batch dispatcher entirely so the test
    # contract ("neither _apply_typed nor _apply_batch is invoked") holds.
    # The renderer block below writes the asymmetric manifest from scratch.
    if mode_mod is not None and mode == mode_mod.Mode.DRY_RUN:
        manifest_path = None
    else:
        manifest_path = _apply_batch(
            outbound_list, pass_id, repo_root=repo_root, binding_store=binding_store
        )

    # -------------------------------------------------------------------------
    # Mode-specific manifest emission (story 286b).
    #
    # When *mode* is provided, replace the flat legacy manifest with the
    # asymmetric shape dispatched by manifest_renderer:
    #
    #   - DRY_RUN / BOOTSTRAP_STRICT  → render_dry_run_or_strict
    #   - BOOTSTRAP_THROTTLE          → render_throttle
    #   - LIVE                        → no manifest file; remove the legacy
    #                                    write and return None
    #
    # The legacy manifest written by _apply_batch is left in place when
    # mode is None (legacy callers depend on it). Otherwise we overwrite or
    # remove it as required by the mode contract.
    # -------------------------------------------------------------------------
    if mode_mod is not None:
        renderer_mod = _load_manifest_renderer()
        applied_for_manifest = list(mutations_list)

        if mode == mode_mod.Mode.LIVE:
            # LIVE: no manifest file per contract. Remove the legacy manifest
            # written by _apply_batch.
            try:
                if manifest_path is not None and Path(manifest_path).exists():
                    Path(manifest_path).unlink()
            except OSError:
                pass
            return None

        if mode == mode_mod.Mode.BOOTSTRAP_THROTTLE:
            rendered = renderer_mod.render_throttle(
                applied_for_manifest, deferred_for_manifest
            )
        else:
            # DRY_RUN and BOOTSTRAP_STRICT share the same renderer.
            rendered = renderer_mod.render_dry_run_or_strict(
                applied_for_manifest, deferred_for_manifest
            )

        rendered_with_meta = {
            "pass_id": pass_id,
            "mode": getattr(mode, "value", str(mode)),
            "applied_count": rendered.get("applied_count", len(applied_for_manifest)),
            "deferred_count": rendered.get(
                "deferred_count", len(deferred_for_manifest)
            ),
            "outbound": rendered.get("outbound"),
            "inbound": rendered.get("inbound"),
        }
        if "spot_check" in rendered:
            rendered_with_meta["spot_check"] = rendered["spot_check"]
        # Also expose the deferred mutations list (sorted) so tests and
        # operators can audit exactly what was held back.
        rendered_with_meta["deferred"] = [
            {
                "direction": str(
                    getattr(getattr(m, "direction", ""), "value", "")
                    or (m.get("direction", "") if isinstance(m, dict) else "")
                ),
                "action": str(
                    getattr(getattr(m, "action", ""), "value", "")
                    or (m.get("action", "") if isinstance(m, dict) else "")
                ),
                "target": _mode_sort_key(m)[2],
            }
            for m in deferred_for_manifest
        ]

        # DRY_RUN may have skipped _apply_batch entirely (when mutations_input
        # was empty) — _apply_batch still wrote an empty manifest. Either way,
        # the manifest_path is valid; overwrite with the asymmetric shape.
        if manifest_path is None:
            if repo_root is None:
                repo_root_resolved = Path(__file__).parents[4]
            else:
                repo_root_resolved = repo_root
            snapshots_dir = repo_root_resolved / "bridge_state" / "snapshots"
            snapshots_dir.mkdir(parents=True, exist_ok=True)
            manifest_path = snapshots_dir / f"{pass_id}.manifest.json"
        # Atomic write via tempfile + os.replace to avoid race conditions
        # when concurrent DRY_RUN passes share the same pass_id (finding #3).
        manifest_dir = Path(manifest_path).parent
        manifest_dir.mkdir(parents=True, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(
            dir=manifest_dir,
            prefix=f"{pass_id}.",
            suffix=".json.tmp",
        )
        try:
            with os.fdopen(fd, "w") as tmp_f:
                json.dump(rendered_with_meta, tmp_f, indent=2)
            os.replace(tmp_path, str(manifest_path))
        except BaseException:
            # Clean up the temp file on any failure.
            with contextlib.suppress(OSError):
                os.unlink(tmp_path)
            raise

    return manifest_path


def _mutation_to_batch_dict(mutation) -> dict:
    """Convert a Mutation dataclass instance to the legacy batch-dict shape.

    The legacy batch consumer (_apply_batch) expects a dict with keys:
    action, fields, key, local_id, follow_on, direction. Map the Mutation
    attributes accordingly so the batch path can iterate without crashing.

    Note: this dict is later passed through `json.dumps` when the manifest
    is written. Every value here MUST be JSON-serializable. Do NOT store
    the original Mutation object as a back-reference — non-serializable.
    """
    payload = dict(mutation.payload) if mutation.payload else {}
    action_value = getattr(mutation.action, "value", str(mutation.action))
    direction_value = getattr(mutation.direction, "value", str(mutation.direction))
    # Use payload.get("fields", payload) — NOT `or payload` — so an
    # intentionally-empty `fields: {}` doesn't truthy-fall-through to the
    # whole payload (which would leak local_id / follow_on / etc. into
    # batch fields). coderabbit-flagged on PR #364.
    return {
        "action": action_value,
        "direction": direction_value,
        "key": mutation.target,
        "fields": payload.get("fields", payload),
        "local_id": payload.get("local_id", ""),
        "follow_on": payload.get("follow_on"),
    }


def _apply_batch(
    mutations: list[dict],
    pass_id: str,
    repo_root: Path | None = None,
    binding_store=None,
) -> Path:
    """Legacy batch dispatch: write a flat-JSON manifest for a list of dict mutations.

    Performs HEAD-pin drift detection before each mutation: captures the
    tickets-branch HEAD SHA before the first mutation, then re-checks before
    each subsequent mutation. If the HEAD changes mid-pass, raises HeadDriftError
    and aborts without issuing further Jira calls.

    Empty mutations list is a no-op fast path (no HEAD check invoked).

    Args:
        mutations: List of mutation dicts, each with at least an "action" field
                   ("create", "update", or "delete").
        pass_id:   Unique identifier for this reconciliation pass.
        repo_root: Repository root directory. Defaults to four levels above this file.

    Returns:
        Path to the written manifest file.

    Raises:
        HeadDriftError:   When the tickets-branch HEAD changes between mutations,
                          indicating a concurrent write by another process.
        RescheduleError:  When rebase_retry exhausts all write attempts
                          (kind='reject_and_reschedule').  A health event JSON is
                          emitted to stderr before the raise.  No retry-counter
                          file is written to disk; the next pass starts fresh.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    acli = _load_acli()
    # Mirror fetcher.fetch_snapshot's pattern: AcliClient's real constructor
    # requires (jira_url, user, api_token) — the no-arg form raises TypeError
    # on every real invocation. Read credentials from the standard
    # JIRA_URL / JIRA_USER / JIRA_API_TOKEN environment variables, defaulting
    # to "" so test/CI shims that monkey-patch _load_acli still work.
    # jira_project defaults to "DIG" (matching _attestation.py) because an empty
    # projectKey is rejected by ACLI on every CREATE — bug 4fa9-0846-519e-4c30.
    client = acli.AcliClient(
        jira_url=os.environ.get("JIRA_URL", ""),
        user=os.environ.get("JIRA_USER", ""),
        api_token=os.environ.get("JIRA_API_TOKEN", ""),
        jira_project=os.environ.get("JIRA_PROJECT", "DIG"),
    )

    rest_calls: int = 0
    deferred_creates: list[dict] = []
    mutations_with_outcomes: list[dict] = []
    events_list: list[dict] = []

    # Load concurrency module once (used both in the fast path and the main loop)
    concurrency = _load_concurrency()

    # Fast path: empty mutation list — skip HEAD check entirely
    if not mutations:
        manifest = {
            "pass_id": pass_id,
            "mutation_count": 0,
            "mutations": [],
            "events": [],
        }
        snapshots_dir = repo_root / "bridge_state" / "snapshots"
        snapshots_dir.mkdir(parents=True, exist_ok=True)
        manifest_path = snapshots_dir / f"{pass_id}.manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2))
        write_result = concurrency.rebase_retry(
            repo_root,
            lambda: _write_pass_record(repo_root, pass_id, 0),
        )
        if not write_result.ok:
            _handle_failed_write_result(write_result, pass_id)
        return manifest_path

    # Pin HEAD before first mutation
    head_pin = concurrency.snapshot_head(repo_root)

    try:
        for mutation in mutations:
            # Re-check HEAD at the start of each iteration
            current_head = concurrency.snapshot_head(repo_root)
            if current_head != head_pin:
                raise HeadDriftError(f"drift: {head_pin[:8]}→{current_head[:8]}")

            action = mutation.get("action", "")
            outcome = dict(mutation)

            # Audit pass: extend the dso-id label write guard to the legacy
            # batch dispatch path. create_one/update_one/delete_one all issue
            # outbound Jira writes, so each batch mutation maps to an
            # outbound_<action> leaf for guard-name purposes. Without this
            # call, _audit_dso_id_label_writes was bypassed for every legacy
            # dict-shaped mutation — only _apply_typed enforced the contract.
            _audit_dso_id_label_writes(
                f"outbound_{action}", [_BatchAuditView(mutation)]
            )

            if action == "create":
                result = create_one(
                    mutation,
                    client,
                    rest_calls=rest_calls,
                    deferred_creates=deferred_creates,
                    events_list=events_list,
                    repo_root=repo_root,
                    binding_store=binding_store,
                )
                # Only count REST call on actual create (not dedup-skipped, not deferred)
                if (
                    result is not None
                    and result.get("status") != "dedup-create-skipped"
                ):
                    rest_calls += 1
                outcome["result"] = result
            elif action == "update":
                result = update_one(mutation, client)
                outcome["result"] = result
                # Persist provenance for set-valued fields after update
                jira_key = mutation.get("key", "")
                if jira_key:
                    conflict_resolver = _load_conflict_resolver()
                    mapping_path = repo_root / "bridge_state" / "mapping.json"
                    for field_name, field_value in mutation.get("fields", {}).items():
                        if conflict_resolver.FIELD_CLASSES.get(field_name) == "set":
                            _persist_field_provenance(
                                mapping_path, jira_key, field_name, field_value
                            )
            elif action == "delete":
                delete_one(mutation, client)
                outcome["result"] = None
            else:
                outcome["result"] = None
                outcome["error"] = f"unknown action: {action!r}"

            mutations_with_outcomes.append(outcome)

    except HeadDriftError:
        # Emit abort event as structured log and re-raise for the caller
        print(
            json.dumps(
                {
                    "kind": "abort_due_to_drift",
                    "pass_id": pass_id,
                    "head_pin": head_pin,
                    "mutations_completed": len(mutations_with_outcomes),
                }
            ),
            file=sys.stderr,
        )
        raise

    manifest = {
        "pass_id": pass_id,
        "mutation_count": len(mutations),
        "mutations": mutations_with_outcomes,
        "events": events_list,
    }

    snapshots_dir = repo_root / "bridge_state" / "snapshots"
    snapshots_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = snapshots_dir / f"{pass_id}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))

    # Wrap the tickets-branch write in rebase_retry (up to 3 attempts).
    # On non-fast-forward push rejection the helper fetches + rebases + retries.
    # On exhaustion, emit a health event to stderr and raise RescheduleError so
    # the process can exit with EXIT_RESCHEDULE.  No retry-counter file is
    # written to disk; the next pass starts fresh.
    write_result = concurrency.rebase_retry(
        repo_root,
        lambda: _write_pass_record(repo_root, pass_id, len(mutations)),
    )
    if not write_result.ok:
        _handle_failed_write_result(write_result, pass_id)

    return manifest_path
