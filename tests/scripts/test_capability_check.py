"""Tests for capability_check.py — identity-layer attestation check."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import sys

# Load module under test via importlib to avoid package import issues
_spec = importlib.util.spec_from_file_location(
    "capability_check",
    pathlib.Path(__file__).parents[2]
    / "plugins/dso/scripts/dso_reconciler/capability_check.py",
)
mod = importlib.util.module_from_spec(_spec)
# Register in sys.modules before exec so dataclass field() resolution works
sys.modules.setdefault("capability_check", mod)
_spec.loader.exec_module(mod)


def test_returns_ok_when_attested_json_with_band_key_exists(tmp_path):
    """ok=True when bootstrap dir contains *.attested.json with a 'band' key."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    bootstrap_dir.mkdir(parents=True)
    attest_file = bootstrap_dir / "bootstrap.attested.json"
    attest_file.write_text(json.dumps({"band": "identity"}))

    result = mod.run(repo_root=tmp_path)

    assert result.ok is True
    assert "attestation found" in result.message


def test_returns_fail_when_bootstrap_dir_absent(tmp_path):
    """ok=False when the bridge_state/bootstrap directory does not exist."""
    nonexistent = tmp_path / "no_such_dir"

    result = mod.run(repo_root=nonexistent)

    assert result.ok is False
    assert "attestation absent" in result.message


def test_returns_fail_when_no_attested_files(tmp_path):
    """ok=False when bootstrap dir exists but contains no *.attested.json files."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    bootstrap_dir.mkdir(parents=True)
    # Create a file that does NOT match the glob pattern
    (bootstrap_dir / "README.txt").write_text("not an attestation")

    result = mod.run(repo_root=tmp_path)

    assert result.ok is False
    assert "attestation absent" in result.message


def test_returns_fail_when_attested_files_missing_band_key(tmp_path):
    """ok=False when *.attested.json files exist but none contain a 'band' key."""
    bootstrap_dir = tmp_path / "bridge_state" / "bootstrap"
    bootstrap_dir.mkdir(parents=True)
    attest_file = bootstrap_dir / "bootstrap.attested.json"
    attest_file.write_text(json.dumps({"type": "wrong"}))

    result = mod.run(repo_root=tmp_path)

    assert result.ok is False
    assert "attestation absent" in result.message


def test_does_not_raise_on_missing_directory(tmp_path):
    """run() must not raise; it should return ok=False for a missing directory."""
    nonexistent = tmp_path / "completely" / "missing"

    # Should not raise any exception
    result = mod.run(repo_root=nonexistent)

    assert result.ok is False
