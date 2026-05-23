#!/usr/bin/env python3
"""Applier: dispatches mutations to AcliClient and writes per-pass flat-JSON manifest."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path


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
    if mapping_path.exists():
        try:
            existing: dict = json.loads(mapping_path.read_text())
        except (json.JSONDecodeError, OSError):
            existing = {}
    else:
        existing = {}

    existing[local_id] = jira_key

    # Write to a sibling temp file then atomically rename
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=mapping_path.parent, suffix=".tmp", prefix="mapping_"
    )
    try:
        with os.fdopen(tmp_fd, "w") as fh:
            json.dump(existing, fh, indent=2)
        os.replace(tmp_path, mapping_path)
    except Exception:
        # Clean up temp file on failure to avoid leftover debris
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


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

    result = _call_with_retry(client.create_issue, mutation.get("fields", {}))

    # Write identity markers so the issue can be re-discovered by dedup JQL
    # and by inbound consumers that inspect entity properties.
    jira_key = result.get("key", "") if isinstance(result, dict) else ""
    if jira_key:
        try:
            client.add_label(jira_key, f"dso-id:{local_id}")
            client.set_entity_property(jira_key, "dso_local_id", local_id)
        except Exception as write_err:
            try:
                client.delete_issue(jira_key)
            except Exception:
                pass  # rollback failure must not mask original error
            raise write_err

    return result


def update_one(mutation: dict, client) -> dict:
    """Update an existing Jira issue from the mutation's key and fields. Returns the client result."""
    return _call_with_retry(
        client.update_issue, mutation.get("key"), mutation.get("fields", {})
    )


def delete_one(mutation: dict, client) -> None:
    """Close a Jira issue by transitioning it to 'Closed'."""
    _call_with_retry(client.transition_issue, mutation.get("key"), "Closed")


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
    mutations: list[dict],
    pass_id: str,
    repo_root: Path | None = None,
) -> Path:
    """Dispatch mutations to AcliClient and write a flat-JSON manifest.

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
    client = acli.AcliClient()

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
