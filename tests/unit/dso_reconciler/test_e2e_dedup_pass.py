"""E2E test: dedup guard prevents duplicate Jira creation.

Integration test wiring differ → applier with a fake AcliClient for one
reconciler pass.  Canonical DD-3 evidence: pre-existing issue with
dso-id label produces zero create_issue calls.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import types
from pathlib import Path
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Module loading helpers
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
DIFFER_PATH = SCRIPTS_DIR / "dso_reconciler" / "differ.py"
APPLIER_PATH = SCRIPTS_DIR / "dso_reconciler" / "applier.py"


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None, f"Cannot load {path}"
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def differ():
    if not DIFFER_PATH.exists():
        pytest.fail(f"differ.py not found at {DIFFER_PATH}")
    return _load_module("e2e_differ", DIFFER_PATH)


@pytest.fixture(scope="module")
def applier():
    if not APPLIER_PATH.exists():
        pytest.fail(f"applier.py not found at {APPLIER_PATH}")
    return _load_module("e2e_applier", APPLIER_PATH)


# ---------------------------------------------------------------------------
# Fake AcliClient
# ---------------------------------------------------------------------------


class FakeAcliClient:
    """Simulates AcliClient with PROJ-999 pre-existing, labeled dso-id:uuid-X."""

    def __init__(self):
        self.creates: list = []
        self.updates: list = []
        self.transitions: list = []

    def search_issues(self, jql: str) -> list:
        # Return the pre-existing issue only when searching for uuid-X's label
        if "uuid-X" in jql:
            return [{"key": "PROJ-999", "labels": ["dso-id:uuid-X"]}]
        return []

    def create_issue(self, fields: dict) -> dict:
        self.creates.append(fields)
        return {"key": "PROJ-NEW"}

    def update_issue(self, key: str, fields: dict) -> dict:
        self.updates.append((key, fields))
        return {"key": key}

    def transition_issue(self, key: str, status: str) -> None:
        self.transitions.append((key, status))


# ---------------------------------------------------------------------------
# Fake concurrency module (avoids git subprocess calls in tmp_path)
# ---------------------------------------------------------------------------

_STABLE_SHA = "deadbeef" * 5  # 40-char stable HEAD for drift guard


def _make_fake_concurrency() -> types.ModuleType:
    """Return a _concurrency stub with a stable HEAD and a no-op rebase_retry."""

    class _FakeResult:
        ok = True
        event = None
        value = None

    def _fake_snapshot_head(_repo_root) -> str:
        return _STABLE_SHA

    def _fake_rebase_retry(_repo_root, write_fn, **_kwargs):
        write_fn()
        return _FakeResult()

    mod = types.ModuleType("_concurrency_e2e_stub")
    mod.snapshot_head = _fake_snapshot_head  # type: ignore[attr-defined]
    mod.rebase_retry = _fake_rebase_retry  # type: ignore[attr-defined]
    return mod


# ---------------------------------------------------------------------------
# E2E test
# ---------------------------------------------------------------------------


def test_pre_existing_dso_id_produces_zero_creates(tmp_path, differ, applier):
    """Pre-existing issue with dso-id label → create_issue never called.

    Pass sequence:
      1. differ.compute_mutations(prev={}, next={"uuid-X": ...}) → [create uuid-X]
      2. applier.apply([create uuid-X], ...) with fake client that returns PROJ-999
         on JQL search for dso-id:uuid-X
      3. Assertions:
         - create_issue call count == 0  (dedup guard fired)
         - mapping.json["uuid-X"] == "PROJ-999"
         - manifest events contains {"event": "dedup-create-skipped", "local_id": "uuid-X"}
    """
    fake_client = FakeAcliClient()
    fake_concurrency = _make_fake_concurrency()

    # Build a fake acli module wrapping our fake client instance
    fake_acli_mod = types.ModuleType("acli_integration")
    fake_acli_mod.AcliClient = lambda: fake_client  # type: ignore[attr-defined]

    # Step 1 — differ: prev=empty, next=has uuid-X → must produce a create mutation
    prev_snapshot: dict = {}
    next_snapshot: dict = {"uuid-X": {"summary": "Test ticket", "status": "open"}}
    mutations = differ.compute_mutations(prev_snapshot, next_snapshot)

    create_mutations = [m for m in mutations if m.get("action") == "create" and m.get("key") == "uuid-X"]
    assert create_mutations, (
        f"differ.compute_mutations must emit a create mutation for uuid-X; got {mutations}"
    )

    # Wire local_id: the differ emits 'key' as the snapshot key; applier's dedup
    # guard reads 'local_id'.  Set local_id = key on each create mutation so the
    # JQL search carries the correct label.
    for m in mutations:
        if m.get("action") == "create" and "local_id" not in m:
            m["local_id"] = m["key"]

    # Step 2 — apply: patch _load_acli and _load_concurrency so applier uses
    # our fakes (no real AcliClient, no git subprocess in tmp_path).
    with patch.object(applier, "_load_acli", return_value=fake_acli_mod), \
         patch.object(applier, "_load_concurrency", return_value=fake_concurrency):
        manifest_path = applier.apply(mutations, "pass-001", repo_root=tmp_path)

    # Step 3 — assertions

    # 3a. create_issue must not be called (dedup guard intercepts)
    assert fake_client.creates == [], (
        "create_issue must NOT be called when dedup guard fires on a pre-existing dso-id label"
    )

    # 3b. mapping.json must record uuid-X → PROJ-999
    mapping_file = tmp_path / "bridge_state" / "mapping.json"
    assert mapping_file.exists(), "mapping.json must be written by the dedup guard"
    mapping = json.loads(mapping_file.read_text())
    assert mapping.get("uuid-X") == "PROJ-999", (
        f"mapping.json must record uuid-X → PROJ-999; got {mapping}"
    )

    # 3c. manifest events must include dedup-create-skipped for uuid-X
    manifest = json.loads(manifest_path.read_text())
    events = manifest.get("events", [])
    dedup_events = [
        e for e in events
        if e.get("event") == "dedup-create-skipped" and e.get("local_id") == "uuid-X"
    ]
    assert dedup_events, (
        f"manifest events must include dedup-create-skipped for uuid-X; got {events}"
    )
