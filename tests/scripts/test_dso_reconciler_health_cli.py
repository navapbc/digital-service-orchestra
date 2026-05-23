"""Tests for dso-reconciler-health.py CLI — summary subcommand.

Story 81cd: "As a bridge operator, I can run `dso-reconciler-health.py summary`
to see a table of reconciler health pass records, so I can monitor
pass-over-pass fsck ratio trends at a glance."
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
CLI_PATH = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "scripts"
    / "dso_reconciler"
    / "dso-reconciler-health.py"
)


def _load_cli():
    spec = importlib.util.spec_from_file_location("dso_reconciler_health", CLI_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["dso_reconciler_health"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def cli():
    """Load the dso-reconciler-health module, failing all tests if absent."""
    if not CLI_PATH.exists():
        pytest.fail(
            f"dso-reconciler-health.py not found at {CLI_PATH} — "
            "implement the CLI to make tests pass."
        )
    return _load_cli()


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

_HEALTH_RECORD_1 = {
    "schema_version": 1,
    "pass_id": "test-pass-001",
    "pre_pass_fsck_total": 10,
    "post_pass_fsck_total": 8,
    "per_type_open_counts": {"epic": 2, "story": 5, "task": 3, "bug": 0},
    "local_mutation_count_at_pass": 3,
    "timestamp_ns": 1700000000000000000,
}

_HEALTH_RECORD_2 = {
    "schema_version": 1,
    "pass_id": "test-pass-002",
    "pre_pass_fsck_total": 15,
    "post_pass_fsck_total": 12,
    "per_type_open_counts": {"epic": 3, "story": 6, "task": 2, "bug": 1},
    "local_mutation_count_at_pass": 5,
    "timestamp_ns": 1700000001000000000,
}

_HEALTH_RECORD_ZERO_PRE = {
    "schema_version": 1,
    "pass_id": "test-pass-zero",
    "pre_pass_fsck_total": 0,
    "post_pass_fsck_total": 0,
    "per_type_open_counts": {},
    "local_mutation_count_at_pass": 0,
    "timestamp_ns": 1700000002000000000,
}


def _write_health_record(health_dir: Path, record: dict) -> Path:
    """Write a health record JSON file to health_dir."""
    health_dir.mkdir(parents=True, exist_ok=True)
    path = health_dir / f"{record['pass_id']}.json"
    path.write_text(json.dumps(record))
    return path


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_summary_prints_table_with_two_records(tmp_path, cli, capsys):
    """Running summary with 2 health JSON files prints a table with all required columns."""
    health_dir = tmp_path / "bridge_state" / "health"
    _write_health_record(health_dir, _HEALTH_RECORD_1)
    _write_health_record(health_dir, _HEALTH_RECORD_2)

    import argparse

    args = argparse.Namespace(health_dir=str(health_dir), command="summary")
    rc = cli.cmd_summary(args)

    captured = capsys.readouterr()
    output = captured.out

    assert rc == 0
    # Header columns must appear
    assert "pass_id" in output
    assert "pre_fsck" in output
    assert "post_fsck" in output
    assert "ratio" in output
    assert "mutations" in output
    # Both records must appear
    assert "test-pass-001" in output
    assert "test-pass-002" in output
    # Ratio values: 8/10=0.80, 12/15=0.80
    assert "0.80" in output
    # Mutation counts
    assert "3" in output
    assert "5" in output


def test_summary_shows_na_ratio_when_pre_fsck_is_zero(tmp_path, cli, capsys):
    """When pre_pass_fsck_total=0, ratio column shows N/A instead of dividing by zero."""
    health_dir = tmp_path / "bridge_state" / "health"
    _write_health_record(health_dir, _HEALTH_RECORD_ZERO_PRE)

    import argparse

    args = argparse.Namespace(health_dir=str(health_dir), command="summary")
    rc = cli.cmd_summary(args)

    captured = capsys.readouterr()
    output = captured.out

    assert rc == 0
    assert "test-pass-zero" in output
    assert "N/A" in output


def test_summary_no_records_when_dir_missing(tmp_path, cli, capsys):
    """When bridge_state/health/ does not exist, prints 'No health records found.'"""
    health_dir = tmp_path / "bridge_state" / "health"
    # Do NOT create the directory

    import argparse

    args = argparse.Namespace(health_dir=str(health_dir), command="summary")
    rc = cli.cmd_summary(args)

    captured = capsys.readouterr()
    output = captured.out

    assert rc == 0
    assert "No health records found." in output


def test_summary_no_records_when_dir_empty(tmp_path, cli, capsys):
    """When bridge_state/health/ exists but has no JSON files, prints 'No health records found.'"""
    health_dir = tmp_path / "bridge_state" / "health"
    health_dir.mkdir(parents=True)
    # Write a non-JSON file to confirm it's ignored
    (health_dir / "README.txt").write_text("not a json file")

    import argparse

    args = argparse.Namespace(health_dir=str(health_dir), command="summary")
    rc = cli.cmd_summary(args)

    captured = capsys.readouterr()
    output = captured.out

    assert rc == 0
    assert "No health records found." in output


def test_main_summary_subcommand_via_argv(tmp_path, cli, capsys):
    """Calling main() with ['--health-dir=<path>', 'summary'] returns 0 and prints table."""
    health_dir = tmp_path / "health"
    _write_health_record(health_dir, _HEALTH_RECORD_1)

    rc = cli.main([f"--health-dir={health_dir}", "summary"])

    captured = capsys.readouterr()
    output = captured.out

    assert rc == 0
    assert "test-pass-001" in output
    assert "pass_id" in output


def test_main_no_subcommand_returns_nonzero(tmp_path, cli, capsys):
    """Calling main() with no subcommand returns non-zero exit code."""
    rc = cli.main(["--health-dir=/nonexistent"])

    assert rc != 0
