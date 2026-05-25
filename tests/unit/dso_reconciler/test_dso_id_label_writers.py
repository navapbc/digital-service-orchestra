"""Tests for the dso-id label write authorization guard in applier.py.

Covers _audit_dso_id_label_writes and its integration into apply():

  1. test_unauthorized_leaf_raises_dso_id_label_write_error
     — direct call to _audit_dso_id_label_writes with an unauthorized leaf
     and a dso-id-* label create mutation (target='label') raises
     DsoIdLabelWriteError.

  2. test_authorized_leaves_pass_audit
     — inbound_clean_label (delete) and outbound_create (create) pass through
     _audit_dso_id_label_writes without raising, even when target='label' and
     payload starts with 'dso-id-'.

  3. test_apply_raises_for_unauthorized_dso_id_label_mutation (behavioral)
     — apply() with inbound_update Mutation carrying a dso-id-* label in
     payload raises DsoIdLabelWriteError after wiring.

  4. test_audit_ignores_non_dso_id_label_mutations
     — mutations where target!='label' or payload doesn't start with 'dso-id-'
     do NOT trigger the guard from an unauthorized leaf.

  5. test_warn_mode_logs_and_does_not_raise
     — DSO_DSO_ID_GUARD_MODE=warn logs a WARNING instead of raising.

  6. test_guard_mode_precedence
     — env var DSO_DSO_ID_GUARD_MODE takes precedence over config; default
     is 'raise'.
"""

from __future__ import annotations

import importlib.util
import logging
import os
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Module paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
APPLIER_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "applier.py"
MUTATION_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "mutation.py"
ERRORS_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "_errors.py"


# ---------------------------------------------------------------------------
# Module loaders
# ---------------------------------------------------------------------------


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _load_applier():
    """Load applier under the canonical 'applier' module name."""
    spec = importlib.util.spec_from_file_location("applier", APPLIER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["applier"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def mut_mod():
    return _load(MUTATION_PATH, "dso_reconciler_mutation_guard")


@pytest.fixture(scope="module")
def errors_mod():
    return _load(ERRORS_PATH, "dso_reconciler_errors_guard")


@pytest.fixture(scope="module")
def applier():
    return _load_applier()


# ---------------------------------------------------------------------------
# Simple mock objects for label-mutation structs
#
# _MockLabelMutation represents a single label-mutation event:
#   target  = 'label'          (the surface being mutated — always 'label')
#   payload = 'dso-id-...'     (the label value string)
#   action  = 'create'|'update'|'delete'
# ---------------------------------------------------------------------------


class _MockLabelMutation:
    """Minimal label-mutation descriptor for direct audit tests."""

    def __init__(self, payload: str, action: str, target: str = "label"):
        self.target = target
        self.payload = payload
        self.action = action

    def __repr__(self) -> str:
        return (
            f"_MockLabelMutation(target={self.target!r}, "
            f"payload={self.payload!r}, action={self.action!r})"
        )


# ---------------------------------------------------------------------------
# Test 1 — unauthorized leaf raises DsoIdLabelWriteError (direct audit call)
# ---------------------------------------------------------------------------


def test_unauthorized_leaf_raises_dso_id_label_write_error(applier, errors_mod):
    """_audit_dso_id_label_writes with unauthorized leaf + dso-id-* create mutation raises."""
    assert hasattr(applier, "_audit_dso_id_label_writes"), (
        "_audit_dso_id_label_writes not found in applier — implement the function"
    )
    # Use applier.DsoIdLabelWriteError to avoid importlib module-identity mismatch.
    assert hasattr(applier, "DsoIdLabelWriteError"), (
        "DsoIdLabelWriteError must be re-exported from applier"
    )
    mut = _MockLabelMutation(payload="dso-id-abc123", action="create")
    with pytest.raises(applier.DsoIdLabelWriteError) as exc_info:
        applier._audit_dso_id_label_writes("inbound_update", [mut])

    assert "inbound_update" in str(exc_info.value)


# ---------------------------------------------------------------------------
# Test 2 — authorized leaves pass audit without raising
# ---------------------------------------------------------------------------


def test_authorized_leaves_pass_audit(applier):
    """inbound_clean_label (delete) and outbound_create (create) do not raise."""
    assert hasattr(applier, "_audit_dso_id_label_writes"), (
        "_audit_dso_id_label_writes not found in applier"
    )
    # inbound_clean_label: authorized for delete
    clean_label_mut = _MockLabelMutation(payload="dso-id-xyz789", action="delete")
    # Should not raise
    applier._audit_dso_id_label_writes("inbound_clean_label", [clean_label_mut])

    # outbound_create: authorized for create
    create_mut = _MockLabelMutation(payload="dso-id-newid", action="create")
    # Should not raise
    applier._audit_dso_id_label_writes("outbound_create", [create_mut])


# ---------------------------------------------------------------------------
# Test 3 — behavioral RED→GREEN: apply() raises through for unauthorized leaf
# ---------------------------------------------------------------------------


def _make_inbound_update_mutation_with_dso_label(mut_mod):
    """Build an inbound update Mutation whose payload signals a dso-id-* label write."""
    # The payload uses target='label' convention at the dict level so the
    # apply()-wired audit can detect the label write.
    return mut_mod.Mutation(
        direction=mut_mod.MutationDirection.inbound,
        action=mut_mod.MutationAction.update,
        target="JIRA-99",
        payload={"target": "label", "label": "dso-id-test-ticket", "action": "create"},
        provenance={"source": "test"},
    )


def test_apply_raises_for_unauthorized_dso_id_label_mutation(applier, mut_mod, errors_mod):
    """BEHAVIORAL GREEN: apply() with inbound_update + dso-id-* label mutation raises DsoIdLabelWriteError.

    After wiring _audit_dso_id_label_writes into apply(), this call must raise.
    (Before wiring: this test fails — that is the RED state.)
    """
    mut = _make_inbound_update_mutation_with_dso_label(mut_mod)
    # Use applier.DsoIdLabelWriteError to avoid importlib module-identity mismatch.
    with pytest.raises(applier.DsoIdLabelWriteError):
        applier.apply(mut, client=None)


# ---------------------------------------------------------------------------
# Test 4 — non-dso-id label mutations from unauthorized leaves do not raise
# ---------------------------------------------------------------------------


def test_audit_ignores_non_dso_id_label_mutations(applier):
    """Non-dso-id-* payloads and non-label targets from unauthorized leaves do not raise."""
    assert hasattr(applier, "_audit_dso_id_label_writes"), (
        "_audit_dso_id_label_writes not found in applier"
    )
    # Payload does not start with 'dso-id-' — should not raise
    non_dso_mut = _MockLabelMutation(payload="some-other-label", action="create")
    applier._audit_dso_id_label_writes("inbound_update", [non_dso_mut])

    # target != 'label' — should not raise even if payload starts with 'dso-id-'
    non_label_target_mut = _MockLabelMutation(
        target="JIRA-11",
        payload="dso-id-something",
        action="create",
    )
    applier._audit_dso_id_label_writes("inbound_update", [non_label_target_mut])


# ---------------------------------------------------------------------------
# Test 5 — warn mode: logs warning, does NOT raise
# ---------------------------------------------------------------------------


def test_warn_mode_logs_and_does_not_raise(applier, errors_mod, caplog):
    """DSO_DSO_ID_GUARD_MODE=warn logs a WARNING instead of raising."""
    assert hasattr(applier, "_audit_dso_id_label_writes"), (
        "_audit_dso_id_label_writes not found in applier"
    )
    mut = _MockLabelMutation(payload="dso-id-warn-test", action="create")
    with patch.dict(os.environ, {"DSO_DSO_ID_GUARD_MODE": "warn"}):
        with caplog.at_level(logging.WARNING):
            # Should NOT raise in warn mode
            applier._audit_dso_id_label_writes("inbound_update", [mut])

    # Check that a warning was logged with the required fields
    warning_records = [r for r in caplog.records if r.levelno >= logging.WARNING]
    assert warning_records, "Expected at least one WARNING log record in warn mode"
    log_text = " ".join(r.getMessage() for r in warning_records)
    assert "DSO_ID_GUARD" in log_text, f"Expected 'DSO_ID_GUARD' in warning; got: {log_text!r}"
    assert "inbound_update" in log_text, f"Expected leaf name in warning; got: {log_text!r}"
    assert "dso-id-warn-test" in log_text, f"Expected payload in warning; got: {log_text!r}"


# ---------------------------------------------------------------------------
# Test 6 — guard mode precedence: env var > config > default raise
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "env_val,config_val,expected_raises",
    [
        # (a) env=warn + config=raise → warn behavior (env wins, no raise)
        ("warn", "raise", False),
        # (b) env=raise + config=warn → raise behavior (env wins)
        ("raise", "warn", True),
        # (c) env unset + config=warn → warn (config fallback)
        (None, "warn", False),
        # (d) env unset + config unset → raise (default)
        (None, None, True),
    ],
    ids=[
        "env_warn_beats_config_raise",
        "env_raise_beats_config_warn",
        "config_warn_when_env_unset",
        "default_raise_when_both_unset",
    ],
)
def test_guard_mode_precedence(applier, errors_mod, env_val, config_val, expected_raises):
    """env var DSO_DSO_ID_GUARD_MODE takes precedence over dso-config.conf key."""
    assert hasattr(applier, "_audit_dso_id_label_writes"), (
        "_audit_dso_id_label_writes not found in applier"
    )
    mut = _MockLabelMutation(payload="dso-id-prec-test", action="create")

    # Save and restore DSO_DSO_ID_GUARD_MODE cleanly
    original_env = os.environ.pop("DSO_DSO_ID_GUARD_MODE", None)
    try:
        if env_val is not None:
            os.environ["DSO_DSO_ID_GUARD_MODE"] = env_val
        # else: env var remains absent

        # Patch the internal config-reader if it exists
        _config_patcher = None
        if hasattr(applier, "_get_dso_id_guard_mode_from_config"):
            _config_patcher = patch.object(
                applier,
                "_get_dso_id_guard_mode_from_config",
                return_value=config_val,
            )
            _config_patcher.start()

        try:
            # Use applier.DsoIdLabelWriteError to avoid importlib module-identity mismatch.
            if expected_raises:
                with pytest.raises(applier.DsoIdLabelWriteError):
                    applier._audit_dso_id_label_writes("inbound_update", [mut])
            else:
                applier._audit_dso_id_label_writes("inbound_update", [mut])
        finally:
            if _config_patcher is not None:
                _config_patcher.stop()
    finally:
        # Restore original env state
        if original_env is not None:
            os.environ["DSO_DSO_ID_GUARD_MODE"] = original_env
        else:
            os.environ.pop("DSO_DSO_ID_GUARD_MODE", None)
