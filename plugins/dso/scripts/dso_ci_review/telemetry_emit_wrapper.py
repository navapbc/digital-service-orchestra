"""dso_ci_review.telemetry_emit_wrapper — fire-and-forget telemetry emitter.

Exposes emit_event() as the single consumer-facing API for 5 DSO telemetry
event types: review_finding, resolver_outcome, arbiter_ruling, tool_finding,
review_cycle.

Design constraints:
  - subprocess.Popen with stdin/stdout/stderr=DEVNULL, close_fds=True,
    start_new_session=True.  NO .wait(), .communicate(), .poll() in hot path.
  - When --key is set: synchronously pre-register event_id in-process BEFORE
    Popen; pass --event-id <id> to child so child uses the parent's id.
    Returns the event_id string.
  - When --link is set: look up link target's event_id from in-process registry;
    if absent, read from event-id-map.json sidecar; fail-open (no link arg) on miss.
  - Returns None (or event_id when key=), never raises.
  - DSO_TELEMETRY_DISABLE=1 → hard no-op bypass (unit-test / CI isolation).
  - atexit handler polls spawned children to reap zombies (no blocking).
"""

from __future__ import annotations

import atexit
import json
import os
import subprocess
import threading
import uuid
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

# In-process registry: logical_key → event_id.
# Protected by _REGISTRY_LOCK for thread safety.
_REGISTRY: dict[str, str] = {}
_REGISTRY_LOCK = threading.Lock()

# Track spawned child processes for atexit reaping.
_CHILDREN: list[subprocess.Popen] = []
_CHILDREN_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------


def _resolve_shim_path() -> str:
    """Resolve path to telemetry-emit.sh.

    Resolution order:
      1. CLAUDE_PLUGIN_ROOT env var + scripts/telemetry/telemetry-emit.sh
      2. Relative to this file: 4 levels up to plugin root, then
         scripts/telemetry/telemetry-emit.sh
    """
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if plugin_root:
        return os.path.join(plugin_root, "scripts", "telemetry", "telemetry-emit.sh")
    # Derive from __file__: this file is at
    #   <repo>/${CLAUDE_PLUGIN_ROOT}/scripts/dso_ci_review/telemetry_emit_wrapper.py
    # 3 dirname levels up from this file's directory reaches the plugin root
    here = Path(__file__).resolve()
    plugin_root_derived = here.parent.parent.parent
    return str(plugin_root_derived / "scripts" / "telemetry" / "telemetry-emit.sh")


def _resolve_artifacts_dir() -> str:
    """Return artifacts dir for event-id-map.json sidecar lookup."""
    return os.environ.get(
        "WORKFLOW_PLUGIN_ARTIFACTS_DIR",
        os.environ.get("ARTIFACTS_DIR", "/tmp"),
    )


# ---------------------------------------------------------------------------
# In-process registry helpers
# ---------------------------------------------------------------------------


def _register_key(key: str, event_id: str) -> None:
    """Register key → event_id in the in-process registry (thread-safe)."""
    with _REGISTRY_LOCK:
        _REGISTRY[key] = event_id


def _lookup_key(key: str) -> Optional[str]:
    """Look up key in the in-process registry first, then sidecar file."""
    # Fast path: in-process registry
    with _REGISTRY_LOCK:
        if key in _REGISTRY:
            return _REGISTRY[key]

    # Slow path: event-id-map.json sidecar in artifacts dir
    artifacts_dir = _resolve_artifacts_dir()
    sidecar = Path(artifacts_dir) / "event-id-map.json"
    try:
        if sidecar.exists():
            data = json.loads(sidecar.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                value = data.get(key)
                if value:
                    # Populate in-process registry from sidecar to avoid repeated I/O
                    with _REGISTRY_LOCK:
                        _REGISTRY[key] = value
                    return value
    except (OSError, json.JSONDecodeError):
        pass

    return None


# ---------------------------------------------------------------------------
# Atexit reaper
# ---------------------------------------------------------------------------


def _atexit_reap_children() -> None:
    """Poll all spawned children to reap completed processes.

    Called by atexit handler and exposed for tests. Never blocks (.poll() only).
    """
    with _CHILDREN_LOCK:
        for proc in _CHILDREN:
            try:
                proc.poll()
            except Exception:  # noqa: BLE001
                pass


# Register the atexit handler once at module load time.
atexit.register(_atexit_reap_children)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def emit_event(
    event_type: str,
    *,
    key: Optional[str] = None,
    link: Optional[str] = None,
    event_id: Optional[str] = None,
    **payload_kwargs,
) -> Optional[str]:
    """Fire-and-forget emit a DSO telemetry event via telemetry-emit.sh.

    Args:
        event_type: One of review_finding, resolver_outcome, arbiter_ruling,
                    tool_finding, review_cycle.
        key: Logical key to register this event under. When given, the
             caller-generated event_id is pre-registered in-process BEFORE
             Popen is called, and --event-id <id> is passed to the child.
             Returns the event_id string.
        link: Logical key of a prior event to link to. Resolves the linked
              event_id from the in-process registry (or sidecar); passes
              --event-id-link <id> to the child. Fail-open: if key not found,
              the arg is simply omitted.
        event_id: Explicit event_id to use (UUID4). If not provided and key
                  is set, a new UUID4 is generated.
        **payload_kwargs: Additional key=value kwargs forwarded as
                          --<key> <value> CLI args (hyphen-normalised).

    Returns:
        event_id string when key= is given; None otherwise.
        Never raises — all errors are silently swallowed.
    """
    # Hard no-op bypass for test isolation
    if os.environ.get("DSO_TELEMETRY_DISABLE") == "1":
        return None

    # --- Synchronous pre-registration BEFORE Popen (key= path) ---
    returned_event_id: Optional[str] = None
    if key is not None:
        if event_id is None:
            event_id = str(uuid.uuid4())
        _register_key(key, event_id)
        returned_event_id = event_id

    # --- Resolve link event_id ---
    link_event_id: Optional[str] = None
    if link is not None:
        link_event_id = _lookup_key(link)
        # fail-open: if not found, we just skip the --event-id-link arg

    # --- Build argv ---
    shim = _resolve_shim_path()
    argv: list[str] = ["bash", shim, "--event-type", event_type]

    # Pass explicit event_id so child uses parent-generated id (key= path)
    if event_id is not None:
        argv.extend(["--event-id", event_id])

    if link_event_id is not None:
        argv.extend(["--event-id-link", link_event_id])

    # Forward additional payload kwargs as --payload-field KEY=VALUE so the
    # emitter injects them into the envelope. Bools / ints / lists / dicts /
    # None are JSON-serialised so the parser at the other end can recover
    # the original Python type — required for the canonical per-event-type
    # schema (e.g. review_cycle.pass must be a bool, not the string "True").
    for k, v in payload_kwargs.items():
        if isinstance(v, (bool, int, float, list, dict)) or v is None:
            serialised = json.dumps(v)
        else:
            serialised = str(v)
        argv.extend(["--payload-field", f"{k}={serialised}"])

    # --- Fire-and-forget via Popen ---
    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=True,
        )
        # Track child for atexit reaping
        with _CHILDREN_LOCK:
            _CHILDREN.append(proc)
    except Exception:  # noqa: BLE001
        # Swallow all errors — telemetry must never block review
        return returned_event_id

    return returned_event_id
