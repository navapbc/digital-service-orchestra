"""Unit tests for dso_reconciler/health.py.

Tests cover:
  - test_record_pass_creates_json_file: record_pass() writes a JSON file at
    bridge_state/health/<pass_id>.json under repo_root.
  - test_record_pass_schema_version: the JSON has schema_version=1.
  - test_record_pass_fields: the JSON contains all required fields with
    correct values.
  - test_record_pass_timestamp_ns_positive: timestamp_ns is a positive integer.
  - test_capture_baseline_is_callable: capture_baseline() is implemented and
    returns a Path (task 15b8 stub removed). Full baseline coverage lives in
    test_health_baseline.py.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
HEALTH_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "health.py"
)


def _load_health() -> ModuleType:
    spec = importlib.util.spec_from_file_location("health", HEALTH_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def health() -> ModuleType:
    return _load_health()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_record_pass_creates_json_file(health: ModuleType, tmp_path: Path) -> None:
    """record_pass() writes a JSON file to bridge_state/health/<pass_id>.json."""
    pass_id = "test-pass-001"
    out_path = health.record_pass(
        pass_id=pass_id,
        pre_fsck=10,
        post_fsck=8,
        per_type_counts={"epic": 2, "story": 3, "task": 2, "bug": 1},
        local_mutation_count=5,
        repo_root=tmp_path,
    )
    expected = tmp_path / "bridge_state" / "health" / f"{pass_id}.json"
    assert out_path == expected
    assert expected.exists(), f"Expected file not found: {expected}"


def test_record_pass_schema_version(health: ModuleType, tmp_path: Path) -> None:
    """The written JSON has schema_version=1."""
    pass_id = "test-pass-schema"
    health.record_pass(
        pass_id=pass_id,
        pre_fsck=0,
        post_fsck=0,
        per_type_counts={},
        local_mutation_count=0,
        repo_root=tmp_path,
    )
    data = json.loads(
        (tmp_path / "bridge_state" / "health" / f"{pass_id}.json").read_text()
    )
    assert data["schema_version"] == 1


def test_record_pass_fields(health: ModuleType, tmp_path: Path) -> None:
    """The JSON contains all required fields with the values passed in."""
    pass_id = "test-pass-fields"
    pre_fsck = 42
    post_fsck = 38
    per_type_counts = {"epic": 5, "story": 10, "task": 20, "bug": 7}
    local_mutation_count = 12

    health.record_pass(
        pass_id=pass_id,
        pre_fsck=pre_fsck,
        post_fsck=post_fsck,
        per_type_counts=per_type_counts,
        local_mutation_count=local_mutation_count,
        repo_root=tmp_path,
    )
    data = json.loads(
        (tmp_path / "bridge_state" / "health" / f"{pass_id}.json").read_text()
    )

    assert data["pass_id"] == pass_id
    assert data["pre_pass_fsck_total"] == pre_fsck
    assert data["post_pass_fsck_total"] == post_fsck
    assert data["per_type_open_counts"] == per_type_counts
    assert data["local_mutation_count_at_pass"] == local_mutation_count
    assert "timestamp_ns" in data


def test_record_pass_timestamp_ns_positive(
    health: ModuleType, tmp_path: Path
) -> None:
    """timestamp_ns is a positive integer."""
    pass_id = "test-pass-ts"
    health.record_pass(
        pass_id=pass_id,
        pre_fsck=1,
        post_fsck=1,
        per_type_counts={},
        local_mutation_count=0,
        repo_root=tmp_path,
    )
    data = json.loads(
        (tmp_path / "bridge_state" / "health" / f"{pass_id}.json").read_text()
    )
    ts = data["timestamp_ns"]
    assert isinstance(ts, int), f"timestamp_ns should be int, got {type(ts)}"
    assert ts > 0, f"timestamp_ns should be positive, got {ts}"


def test_capture_baseline_is_callable(
    health: ModuleType, tmp_path: Path
) -> None:
    """capture_baseline() is implemented and returns a Path (task 15b8 stub removed)."""
    result = health.capture_baseline(pass_id="test-baseline", repo_root=tmp_path)
    assert isinstance(result, Path)
    assert result.exists()


def test_count_open_by_type_empty_tracker(health: ModuleType, tmp_path: Path) -> None:
    """count_open_by_type returns {} when .tickets-tracker/ is absent."""
    result = health.count_open_by_type(repo_root=tmp_path)
    assert result == {}


def test_count_open_by_type_counts_correctly(health: ModuleType, tmp_path: Path) -> None:
    """count_open_by_type counts open tickets by type from .tickets-tracker/.

    Events use the canonical reducer shape: type/status live under event["data"],
    not the top level.
    """
    import json as _json
    import time

    tracker = tmp_path / ".tickets-tracker"
    for tid, ttype, tstatus in [
        ("t1", "story", "open"),
        ("t2", "task", "open"),
        ("t3", "story", "closed"),
        ("t4", "bug", "open"),
        ("t5", "task", "open"),
    ]:
        d = tracker / tid
        d.mkdir(parents=True)
        ts = time.time_ns()
        (d / f"{ts}-create.json").write_text(
            _json.dumps({"event_type": "CREATE", "data": {"ticket_type": ttype}})
        )
        (d / f"{ts + 1}-status.json").write_text(
            _json.dumps({"event_type": "STATUS", "data": {"status": tstatus}})
        )

    result = health.count_open_by_type(repo_root=tmp_path)
    assert result == {"story": 1, "task": 2, "bug": 1}


def test_count_open_by_type_defaults_open_when_only_create(
    health: ModuleType, tmp_path: Path
) -> None:
    """A ticket with only a CREATE event (no STATUS yet) counts as open.

    Matches ticket_reducer/_state.py:make_initial_state which initializes
    status="open" — newly-created tickets are canonically open before any
    transition event is recorded.
    """
    import json as _json
    import time

    tracker = tmp_path / ".tickets-tracker"
    d = tracker / "fresh-ticket"
    d.mkdir(parents=True)
    ts = time.time_ns()
    (d / f"{ts}-create.json").write_text(
        _json.dumps({"event_type": "CREATE", "data": {"ticket_type": "story"}})
    )
    # No STATUS event written

    result = health.count_open_by_type(repo_root=tmp_path)
    assert result == {"story": 1}


def test_count_open_by_type_skips_non_dict_events(
    health: ModuleType, tmp_path: Path
) -> None:
    """Non-dict JSON payloads in event files do not crash the walker."""
    import json as _json
    import time

    tracker = tmp_path / ".tickets-tracker"
    d = tracker / "weird-ticket"
    d.mkdir(parents=True)
    ts = time.time_ns()
    # A scalar JSON value (not a dict) — defensive: do not crash.
    (d / f"{ts}-garbage.json").write_text(_json.dumps(42))
    (d / f"{ts + 1}-create.json").write_text(
        _json.dumps({"event_type": "CREATE", "data": {"ticket_type": "task"}})
    )

    result = health.count_open_by_type(repo_root=tmp_path)
    assert result == {"task": 1}
