"""Tests for bridge-reconcile-types.py — one-shot EDIT event emitter.

Covers: field translation (type capitalize, priority int→name), JSON structure
of emitted EDIT events, dry-run mode (no files written), and idempotency
(already-correct tickets produce no EDIT events).
"""

from __future__ import annotations

import importlib.util
import json
import time
import uuid
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge" / "bridge-reconcile-types.py"
)

# ---------------------------------------------------------------------------
# Module loader
# ---------------------------------------------------------------------------


def _load_reconcile() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bridge_reconcile_types", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def reconcile_mod() -> ModuleType:
    return _load_reconcile()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000099"


def _write_create_event(
    ticket_dir: Path, ticket_type: str, priority: int | None
) -> None:
    ts = time.time_ns()
    eu = str(uuid.uuid4())
    data: dict = {"ticket_type": ticket_type, "title": "Test ticket"}
    if priority is not None:
        data["priority"] = priority
    payload = {
        "event_type": "CREATE",
        "timestamp": ts,
        "uuid": eu,
        "env_id": _BRIDGE_ENV_ID,
        "ticket_id": ticket_dir.name,
        "data": data,
    }
    path = ticket_dir / f"{ts}-{eu}-CREATE.json"
    path.write_text(json.dumps(payload), encoding="utf-8")


def _write_sync_file(ticket_dir: Path, jira_key: str = "DIG-999") -> None:
    ts = time.time_ns()
    eu = str(uuid.uuid4())
    path = ticket_dir / f"{ts}-{eu}-SYNC.json"
    path.write_text(json.dumps({"jira_key": jira_key}), encoding="utf-8")


def _setup_ticket(
    tickets_root: Path,
    ticket_id: str,
    ticket_type: str,
    priority: int | None,
    jira_key: str = "DIG-999",
) -> Path:
    ticket_dir = tickets_root / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)
    _write_create_event(ticket_dir, ticket_type, priority)
    _write_sync_file(ticket_dir, jira_key)
    return ticket_dir


# ---------------------------------------------------------------------------
# reconcile() — EDIT event emission
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reconcile_emits_edit_for_lowercase_ticket_type(
    tmp_path: Path, reconcile_mod: ModuleType
) -> None:
    """When ticket_type in CREATE event is lowercase (e.g. 'task'), reconcile()
    must emit an EDIT event so the outbound bridge can re-capitalize it in Jira.
    """
    tickets_root = tmp_path / ".tickets-tracker"
    _setup_ticket(tickets_root, "ticket-type-fix", "task", priority=None)

    count = reconcile_mod.reconcile(tickets_root, bridge_env_id=_BRIDGE_ENV_ID)

    assert count == 1, f"Expected 1 EDIT event emitted; got {count}"
    edit_files = list(tickets_root.rglob("*-EDIT.json"))
    assert len(edit_files) == 1, f"Expected 1 EDIT file on disk; got {len(edit_files)}"

    payload = json.loads(edit_files[0].read_text(encoding="utf-8"))
    assert payload["event_type"] == "EDIT"
    assert payload["ticket_id"] == "ticket-type-fix"
    assert "fields" in payload["data"], "EDIT payload must have a 'fields' key in data"
    assert "ticket_type" in payload["data"]["fields"], (
        "fields must include 'ticket_type' for a lowercase-type fix"
    )
    assert payload["data"]["fields"]["ticket_type"] == "task"


@pytest.mark.unit
@pytest.mark.scripts
def test_reconcile_emits_edit_for_integer_priority(
    tmp_path: Path, reconcile_mod: ModuleType
) -> None:
    """When priority in CREATE event is a translatable integer (0–4), reconcile()
    must emit an EDIT event so the outbound bridge can re-translate it to a
    Jira priority name.
    """
    tickets_root = tmp_path / ".tickets-tracker"
    _setup_ticket(tickets_root, "ticket-priority-fix", "Task", priority=2)

    count = reconcile_mod.reconcile(tickets_root, bridge_env_id=_BRIDGE_ENV_ID)

    assert count == 1, f"Expected 1 EDIT event; got {count}"
    edit_files = list(tickets_root.rglob("*-EDIT.json"))
    assert len(edit_files) == 1

    payload = json.loads(edit_files[0].read_text(encoding="utf-8"))
    assert payload["data"]["fields"].get("priority") == 2, (
        "EDIT fields must carry the integer priority for re-translation by handler"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_reconcile_edit_event_json_structure(
    tmp_path: Path, reconcile_mod: ModuleType
) -> None:
    """Emitted EDIT events must conform to the bridge event envelope:
    event_type, timestamp (int), uuid (str), env_id, ticket_id, data.fields.
    """
    tickets_root = tmp_path / ".tickets-tracker"
    _setup_ticket(tickets_root, "ticket-structure", "story", priority=1)

    reconcile_mod.reconcile(tickets_root, bridge_env_id=_BRIDGE_ENV_ID)

    edit_files = list(tickets_root.rglob("*-EDIT.json"))
    assert edit_files, "At least one EDIT file must be emitted"
    payload = json.loads(edit_files[0].read_text(encoding="utf-8"))

    assert payload.get("event_type") == "EDIT"
    assert isinstance(payload.get("timestamp"), int), "timestamp must be an integer"
    assert isinstance(payload.get("uuid"), str) and payload["uuid"], (
        "uuid must be non-empty str"
    )
    assert payload.get("env_id") == _BRIDGE_ENV_ID
    assert isinstance(payload.get("ticket_id"), str) and payload["ticket_id"]
    assert isinstance(payload.get("data"), dict)
    assert isinstance(payload["data"].get("fields"), dict)


@pytest.mark.unit
@pytest.mark.scripts
def test_reconcile_dry_run_writes_no_files(
    tmp_path: Path, reconcile_mod: ModuleType
) -> None:
    """dry_run=True must print what would be emitted but write zero files."""
    tickets_root = tmp_path / ".tickets-tracker"
    _setup_ticket(tickets_root, "ticket-dryrun", "task", priority=0)

    count = reconcile_mod.reconcile(
        tickets_root, bridge_env_id=_BRIDGE_ENV_ID, dry_run=True
    )

    assert count == 1, "dry_run must still report 1 would-be EDIT"
    edit_files = list(tickets_root.rglob("*-EDIT.json"))
    assert edit_files == [], f"dry_run must write no files; found: {edit_files}"


@pytest.mark.unit
@pytest.mark.scripts
def test_reconcile_no_edit_for_correct_type(
    tmp_path: Path, reconcile_mod: ModuleType
) -> None:
    """When ticket_type is already capitalized and priority is absent,
    reconcile() must emit zero EDIT events (idempotent).
    """
    tickets_root = tmp_path / ".tickets-tracker"
    _setup_ticket(tickets_root, "ticket-no-fix", "Task", priority=None)

    count = reconcile_mod.reconcile(tickets_root, bridge_env_id=_BRIDGE_ENV_ID)

    assert count == 0, f"Already-correct ticket must produce 0 EDIT events; got {count}"
    edit_files = list(tickets_root.rglob("*-EDIT.json"))
    assert edit_files == [], f"No EDIT files should be written; found: {edit_files}"


@pytest.mark.unit
@pytest.mark.scripts
def test_reconcile_skips_ticket_without_sync(
    tmp_path: Path, reconcile_mod: ModuleType
) -> None:
    """Tickets without a SYNC.json (not yet synced to Jira) must be skipped."""
    tickets_root = tmp_path / ".tickets-tracker"
    ticket_dir = tickets_root / "ticket-no-sync"
    ticket_dir.mkdir(parents=True)
    _write_create_event(ticket_dir, "task", priority=1)
    # No SYNC.json written

    count = reconcile_mod.reconcile(tickets_root, bridge_env_id=_BRIDGE_ENV_ID)

    assert count == 0, "Ticket without SYNC.json must be skipped"
