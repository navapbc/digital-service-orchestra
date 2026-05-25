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

import importlib.util
import json
import os
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

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
_MutationModule = None  # late-loaded mutation module
_ErrorsModule = None    # late-loaded _errors module


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


def _load_mutation_module():
    """Lazy-load the mutation module via importlib (same pattern as _load_acli)."""
    global _MutationModule
    if _MutationModule is not None:
        return _MutationModule
    mut_path = Path(__file__).parent / "mutation.py"
    spec = importlib.util.spec_from_file_location(
        "dso_reconciler_mutation", mut_path
    )
    if spec is None:
        raise FileNotFoundError(f"mutation.py not found at {mut_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("dso_reconciler_mutation", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    _MutationModule = mod
    return mod


def _load_errors_module():
    """Lazy-load _errors module."""
    global _ErrorsModule
    if _ErrorsModule is not None:
        return _ErrorsModule
    err_path = Path(__file__).parent / "_errors.py"
    spec = importlib.util.spec_from_file_location(
        "dso_reconciler_errors", err_path
    )
    if spec is None:
        raise FileNotFoundError(f"_errors.py not found at {err_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("dso_reconciler_errors", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    _ErrorsModule = mod
    return mod


def _direction_guard(mutation, expected_direction) -> None:
    """Defense-in-depth: assert mutation.direction matches the leaf's declared
    direction. In normal flow _LEAVES lookup already routes correctly; this
    raises DirectionMismatchError if a leaf is invoked directly with the wrong
    direction (e.g. via the test harness bypassing _LEAVES).
    """
    if mutation.direction is not expected_direction:
        errs = _load_errors_module()
        raise errs.DirectionMismatchError(
            f"leaf expects direction={expected_direction.value!s}, "
            f"got direction={mutation.direction.value!s}"
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


def _apply_outbound_create(mutation, *, client=None) -> ApplyResult:
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
        except Exception:
            pass
        raise
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_outbound_update(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_outbound_delete(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_outbound_probe(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_outbound_conflict(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.outbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_inbound_create(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_inbound_update(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_inbound_delete(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_inbound_probe(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_inbound_clean_label(mutation, *, client=None) -> ApplyResult:
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


def _apply_inbound_repair_property(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    return ApplyResult(mutation.direction, mutation.action, {})


def _apply_inbound_conflict(mutation, *, client=None) -> ApplyResult:
    mut_mod = _load_mutation_module()
    _direction_guard(mutation, mut_mod.MutationDirection.inbound)
    return ApplyResult(mutation.direction, mutation.action, {})


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


def _apply_typed(mutation, *, client=None) -> ApplyResult:
    """Typed-mutation dispatch via _LEAVES.

    Looks up (mutation.direction, mutation.action) in _LEAVES and invokes the
    handler. Raises UnknownActionError with zero side-effects (no client calls,
    no I/O) if the pair is not registered.
    """
    key = (mutation.direction, mutation.action)
    handler = _LEAVES.get(key)
    if handler is None:
        errs = _load_errors_module()
        raise errs.UnknownActionError(
            f"unknown (direction={mutation.direction.value!s}, "
            f"action={mutation.action.value!s})"
        )
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
                _alert_root = (repo_root or Path(__file__).parents[4]) / ".tickets-tracker"
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
                _alert_path.write_text(_json.dumps({
                    "event_type": "BRIDGE_ALERT",
                    "timestamp": _ts,
                    "uuid": _alert_uuid,
                    "ticket_id": local_id,
                    "jira_key": jira_key,
                    "data": {
                        "reason": "identity-write failed after create; Jira issue deleted",
                        "tag": "create-identity-write-failed",
                    },
                }))
            except Exception:
                pass  # alert write failure must not mask original error
            raise write_err

    return result


def update_one(mutation: dict, client) -> dict:
    """Update an existing Jira issue from the mutation's key and fields.

    F3: AcliClient.update_issue's real signature is ``update_issue(jira_key, **kwargs)``;
    the field dict must be unpacked into keyword arguments rather than passed
    positionally as a single dict — otherwise Jira receives a TypeError on every
    real update call.
    """
    fields = mutation.get("fields", {})
    if not isinstance(fields, dict):
        fields = {}
    return _call_with_retry(client.update_issue, mutation.get("key"), **fields)


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


def apply(
    mutations=None,
    pass_id: str | None = None,
    repo_root: Path | None = None,
    *,
    client=None,
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
        return _apply_typed(mutations, client=client)

    # Legacy batch path requires pass_id.
    if pass_id is None:
        raise TypeError(
            "apply() legacy batch form requires pass_id as the second argument"
        )
    return _apply_batch(mutations or [], pass_id, repo_root=repo_root)


def _apply_batch(
    mutations: list[dict],
    pass_id: str,
    repo_root: Path | None = None,
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

            if action == "create":
                result = create_one(
                    mutation,
                    client,
                    rest_calls=rest_calls,
                    deferred_creates=deferred_creates,
                    events_list=events_list,
                    repo_root=repo_root,
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
                        if (
                            conflict_resolver.FIELD_CLASSES.get(field_name) == "set"
                        ):
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
