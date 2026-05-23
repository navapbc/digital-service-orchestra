"""telemetry_emit.py — DSO telemetry event emitter (stdlib only, Python ≥3.11).

Canonical schema: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/telemetry-event-schema.md
Story: 6d14-1052-0da5-43b1   Task: 3113-2412-4e43-41eb

CLI contract (matches telemetry-emit.sh shim):
  python3 telemetry_emit.py --event-type <enum> [--endpoint URL]
      [--key LOGICAL_ID] [--link LOGICAL_ID]
      [--cited-excerpt TEXT] [--cycle N] [--language LANG]

Exit codes:
  0 — success (or fail-open on transient network/HTTP errors)
  1 — validation error (empty client_id, unknown event_type)
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import socket
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_CANONICAL_EVENT_TYPES: frozenset[str] = frozenset(
    [
        "review_finding",
        "resolver_outcome",
        "arbiter_ruling",
        "tool_finding",
        "review_cycle",
    ]
)

_SCHEMA_VERSION: int = 1

# Default socket timeout (seconds); overridable via DSO_TELEMETRY_TIMEOUT env var.
_DEFAULT_TIMEOUT: float = 5.0


# ---------------------------------------------------------------------------
# Resolver functions — one per schema field
# ---------------------------------------------------------------------------


def _resolve_schema_version() -> int:
    """Return the schema version as a numeric integer (not a string)."""
    return _SCHEMA_VERSION


def _resolve_event_id() -> str:
    """Return a new UUID v4 string, or use DSO_TELEMETRY_EVENT_ID if set (for tests)."""
    override = os.environ.get("DSO_TELEMETRY_EVENT_ID", "")
    if override:
        return override
    return str(uuid.uuid4())


def _resolve_event_type(event_type: str) -> str:
    """Validate and return event_type; raise ValueError on unknown value."""
    if event_type not in _CANONICAL_EVENT_TYPES:
        raise ValueError(
            f"event_type: invalid value '{event_type}'. "
            f"Must be one of: {sorted(_CANONICAL_EVENT_TYPES)}"
        )
    return event_type


def _resolve_client_id(client_id: str) -> str:
    """Return client_id; raise ValueError when empty or missing."""
    if not client_id:
        raise ValueError(
            "client_id: required and must be non-empty. "
            "Set telemetry.client_id in dso-config.conf."
        )
    return client_id


def _resolve_tool_id(tool_id: str) -> str:
    """Return the configured tool ID as-is."""
    return tool_id


def _resolve_tool_version(tool_version: str) -> str:
    """Return the configured tool version string as-is."""
    return tool_version


def _resolve_timestamp() -> str:
    """Return an ISO 8601 UTC timestamp string (e.g. '2026-05-22T14:30:00.123456Z')."""
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _resolve_pr_number() -> int | None:
    """Return GITHUB_PR_NUMBER as int when in a CI/PR context; None otherwise."""
    raw = os.environ.get("GITHUB_PR_NUMBER", "")
    if raw:
        try:
            return int(raw)
        except ValueError:
            return None
    return None


def _resolve_commit_sha() -> str | None:
    """Return GITHUB_SHA when set; fall back to `git rev-parse HEAD`; None on failure."""
    sha = os.environ.get("GITHUB_SHA", "")
    if sha:
        return sha
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip() or None
    except Exception:  # noqa: BLE001
        pass
    return None


def _resolve_cycle(cycle: int | None = None) -> int:
    """Return explicit cycle value, defaulting to 1 when not provided."""
    if cycle is None:
        return 1
    return int(cycle)


def _resolve_language(language: str | None = None) -> str | None:
    """Return explicit language string; None when not provided (omit field, per schema)."""
    # Per gap-analysis AC amendment: language defaults to None (omit field) when no
    # --language flag passed. Do NOT auto-derive from filesystem scanning.
    return language if language is not None else None


# ---------------------------------------------------------------------------
# Privacy layer
# ---------------------------------------------------------------------------


def _apply_layer_a_privacy(envelope: dict[str, Any], config: dict[str, str]) -> None:
    """Apply Layer A privacy: strip cited_excerpt when emit_excerpts is unset/false
    AND client_id is not 'dso-self'.

    Modifies envelope in-place. Uses delete (not None assignment) so that the
    subsequent None-filter omit step is redundant — the key is fully removed here.
    """
    emit_excerpts = config.get("telemetry.emit_excerpts", "false").lower()
    client_id = envelope.get("client_id", "")
    if emit_excerpts not in ("true", "1", "yes") and client_id != "dso-self":
        envelope.pop("cited_excerpt", None)


# ---------------------------------------------------------------------------
# Key/link registry (event-id-map.json) with fcntl.flock
# ---------------------------------------------------------------------------


def _ledger_dir() -> Path:
    """Return the ledger directory path from DSO_TELEMETRY_LEDGER_DIR, defaulting to /tmp."""
    path = os.environ.get("DSO_TELEMETRY_LEDGER_DIR", "")
    if path:
        d = Path(path)
    else:
        d = Path("/tmp/dso-telemetry-ledger")
    d.mkdir(parents=True, exist_ok=True)
    return d


def _event_id_map_path(ledger: Path) -> Path:
    return ledger / "event-id-map.json"


def _event_id_map_lock_path(ledger: Path) -> Path:
    return ledger / ".event-id-map.lock"


def _register_key(event_id: str, key: str) -> None:
    """Register logical key → event_id in event-id-map.json using fcntl.flock."""
    ledger = _ledger_dir()
    map_file = _event_id_map_path(ledger)
    lock_file = _event_id_map_lock_path(ledger)

    with open(lock_file, "a") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            existing: dict[str, str] = {}
            if map_file.exists():
                try:
                    existing = json.loads(map_file.read_text())
                except (json.JSONDecodeError, OSError):
                    existing = {}
            existing[key] = event_id
            # Atomic write via temp+rename
            tmp = map_file.with_suffix(".tmp")
            tmp.write_text(json.dumps(existing))
            tmp.rename(map_file)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def _lookup_link(key: str) -> str | None:
    """Look up a logical key in event-id-map.json; return event_id or None."""
    ledger = _ledger_dir()
    map_file = _event_id_map_path(ledger)
    lock_file = _event_id_map_lock_path(ledger)

    with open(lock_file, "a") as lf:
        fcntl.flock(lf, fcntl.LOCK_SH)
        try:
            if not map_file.exists():
                return None
            try:
                data = json.loads(map_file.read_text())
                return data.get(key)
            except (json.JSONDecodeError, OSError):
                return None
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


# ---------------------------------------------------------------------------
# Idempotency check (submitted.log)
# ---------------------------------------------------------------------------


def _submitted_log_path(ledger: Path) -> Path:
    return ledger / "submitted.log"


def _check_idempotency(event_id: str) -> bool:
    """Return True if event_id has already been submitted (skip POST); False otherwise."""
    ledger = _ledger_dir()
    log_path = _submitted_log_path(ledger)
    if not log_path.exists():
        return False
    try:
        return event_id in log_path.read_text()
    except OSError:
        return False


def _record_submitted(event_id: str) -> None:
    """Append event_id to submitted.log."""
    ledger = _ledger_dir()
    log_path = _submitted_log_path(ledger)
    try:
        with open(log_path, "a") as f:
            f.write(event_id + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Config reader
# ---------------------------------------------------------------------------


def _read_config(config_file: str | None = None) -> dict[str, str]:
    """Parse a simple key=value config file into a dict.

    Respects DSO_CONFIG_FILE env var override (bug 3319 — test isolation).
    """
    # Priority: explicit arg → DSO_CONFIG_FILE env var → default path
    path: str | None = config_file
    if path is None:
        path = os.environ.get("DSO_CONFIG_FILE", "")
    if not path:
        # Resolve default relative to repo root
        script_dir = Path(__file__).resolve().parent
        # scripts/telemetry/ → scripts/ → ${CLAUDE_PLUGIN_ROOT}/ → repo root
        repo_root = script_dir.parents[3]
        path = str(repo_root / ".claude" / "dso-config.conf")

    config: dict[str, str] = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, _, v = line.partition("=")
                    config[k.strip()] = v.strip()
    except (OSError, FileNotFoundError):
        pass
    return config


# ---------------------------------------------------------------------------
# HTTP POST
# ---------------------------------------------------------------------------


def _post_event(endpoint: str, payload: dict[str, Any]) -> None:
    """POST JSON payload to endpoint. Fail-open: all exceptions emit stderr warning."""
    timeout = float(os.environ.get("DSO_TELEMETRY_TIMEOUT", str(_DEFAULT_TIMEOUT)))
    body = json.dumps(payload).encode("utf-8")
    req = Request(
        endpoint,
        data=body,
        headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
        method="POST",
    )
    old_timeout = socket.getdefaulttimeout()
    socket.setdefaulttimeout(timeout)
    try:
        with urlopen(req) as resp:
            status = resp.status
            if status >= 400:
                print(
                    f"[telemetry] WARNING: POST {endpoint} returned HTTP {status}",
                    file=sys.stderr,
                )
    except HTTPError as exc:
        print(
            f"[telemetry] WARNING: POST {endpoint} HTTP error: {exc.code} {exc.reason}",
            file=sys.stderr,
        )
    except URLError as exc:
        print(
            f"[telemetry] WARNING: POST {endpoint} failed to connect: {exc.reason}",
            file=sys.stderr,
        )
    except OSError as exc:
        print(
            f"[telemetry] WARNING: POST {endpoint} network error: {exc}",
            file=sys.stderr,
        )
    except Exception as exc:  # noqa: BLE001
        print(
            f"[telemetry] WARNING: POST {endpoint} unexpected error: {exc}",
            file=sys.stderr,
        )
    finally:
        socket.setdefaulttimeout(old_timeout)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="telemetry_emit",
        description="Emit a DSO telemetry event (schema v1).",
    )
    parser.add_argument(
        "--event-type",
        required=True,
        help="Event type (one of: review_finding, resolver_outcome, arbiter_ruling, "
        "tool_finding, review_cycle)",
    )
    parser.add_argument(
        "--endpoint",
        default=None,
        help="Override telemetry endpoint URL.",
    )
    parser.add_argument(
        "--key",
        default=None,
        help="Register event_id under this logical key in event-id-map.json.",
    )
    parser.add_argument(
        "--link",
        default=None,
        help="Look up this logical key to populate finding_event_id.",
    )
    parser.add_argument(
        "--cited-excerpt",
        default=None,
        dest="cited_excerpt",
        help="Verbatim code excerpt (Layer A privacy applies).",
    )
    parser.add_argument(
        "--cycle",
        type=int,
        default=None,
        help="Review cycle number (default 1).",
    )
    parser.add_argument(
        "--language",
        default=None,
        help="Language context (omit field when not provided).",
    )
    parser.add_argument(
        "--event-id",
        default=None,
        dest="event_id",
        help="Explicit event_id (UUID4) to use instead of generating one. "
        "Used by telemetry_emit_wrapper.py to ensure the child uses the "
        "parent-generated id (race-safe key/link protocol).",
    )
    parser.add_argument(
        "--event-id-link",
        default=None,
        dest="event_id_link",
        help="event_id of a prior event to link to (finding_event_id field). "
        "Takes precedence over --link lookup when provided directly by the parent.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Main entry point. Returns exit code."""
    parser = _build_parser()
    args = parser.parse_args(argv)

    # Load config (respects DSO_CONFIG_FILE env var)
    config = _read_config()

    # Check telemetry.enabled — no-op exit when disabled
    enabled = config.get("telemetry.enabled", "true").lower()
    if enabled in ("false", "0", "no"):
        return 0

    # Validate event_type (raises ValueError on unknown → exit 1)
    try:
        event_type = _resolve_event_type(args.event_type)
    except ValueError as exc:
        print(f"[telemetry] ERROR: {exc}", file=sys.stderr)
        return 1

    # Validate client_id (raises ValueError on empty → exit 1)
    raw_client_id = config.get("telemetry.client_id", "")
    try:
        client_id = _resolve_client_id(raw_client_id)
    except ValueError as exc:
        print(f"[telemetry] ERROR: {exc}", file=sys.stderr)
        return 1

    # Resolve all fields
    # --event-id from CLI takes precedence over generated id (parent-generated in wrapper)
    event_id = args.event_id if args.event_id else _resolve_event_id()
    tool_id = _resolve_tool_id(config.get("telemetry.tool_id", "dso"))
    tool_version = _resolve_tool_version(config.get("telemetry.tool_version", ""))
    timestamp = _resolve_timestamp()
    pr_number = _resolve_pr_number()
    commit_sha = _resolve_commit_sha()
    cycle = _resolve_cycle(args.cycle)
    language = _resolve_language(args.language)

    # Determine endpoint
    endpoint = args.endpoint or config.get("telemetry.endpoint", "")

    # Build envelope — include all fields, then strip None-valued optional fields
    envelope: dict[str, Any] = {
        "schema_version": _resolve_schema_version(),
        "event_id": event_id,
        "event_type": event_type,
        "client_id": client_id,
        "tool_id": tool_id,
        "tool_version": tool_version,
        "timestamp": timestamp,
        "pr_number": pr_number,
        "commit_sha": commit_sha,
        "cycle": cycle,
        "language": language,
    }

    # Add cited_excerpt if provided (before privacy strip)
    if args.cited_excerpt is not None:
        envelope["cited_excerpt"] = args.cited_excerpt

    # Add finding_event_id:
    #   1. --event-id-link takes precedence (parent resolved the id before Popen)
    #   2. --link triggers sidecar lookup
    if args.event_id_link is not None:
        envelope["finding_event_id"] = args.event_id_link
    elif args.link is not None:
        linked_id = _lookup_link(args.link)
        if linked_id:
            envelope["finding_event_id"] = linked_id

    # Apply Layer A privacy (strips cited_excerpt when emit_excerpts unset/false)
    _apply_layer_a_privacy(envelope, config)

    # Omit None-valued optional fields (OMIT not null per schema line 32)
    envelope = {k: v for k, v in envelope.items() if v is not None}

    # Register key → event_id mapping (before POST so lookups are consistent)
    if args.key is not None:
        _register_key(event_id, args.key)

    # Idempotency check
    if _check_idempotency(event_id):
        # Already submitted — exit 0 without re-posting
        return 0

    # POST (fail-open)
    if endpoint:
        _post_event(endpoint, envelope)

    # Record as submitted
    _record_submitted(event_id)

    return 0


if __name__ == "__main__":
    sys.exit(main())
