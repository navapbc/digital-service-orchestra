"""Tests for --parity-check flag on dso-reconciler-health.py summary subcommand.

Story 5211: "As a bridge operator, I can run `dso-reconciler-health.py summary
--parity-check` to compare the latest health record's open-count totals against
the live ticket store, so I can detect count drift at a glance."
"""

from __future__ import annotations

import argparse
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
    spec = importlib.util.spec_from_file_location(
        "dso_reconciler_health_parity", CLI_PATH
    )
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["dso_reconciler_health_parity"] = mod
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

_HEALTH_RECORD = {
    "schema_version": 1,
    "pass_id": "p1",
    "per_type_open_counts": {"epic": 2, "story": 5, "task": 3, "bug": 0},
    "pre_pass_fsck_total": 10,
    "post_pass_fsck_total": 8,
    "local_mutation_count_at_pass": 3,
    "timestamp_ns": 1700000000000000000,
}

# Total from per_type_open_counts: 2+5+3+0 = 10


def _write_health_record(health_dir: Path, record: dict) -> Path:
    health_dir.mkdir(parents=True, exist_ok=True)
    path = health_dir / f"{record['pass_id']}.json"
    path.write_text(json.dumps(record))
    return path


def _make_ticket_dirs(tickets_dir: Path, count: int) -> None:
    """Create *count* ticket subdirs each containing a ticket.json file."""
    tickets_dir.mkdir(parents=True, exist_ok=True)
    for i in range(count):
        ticket_dir = tickets_dir / f"ticket-{i:04d}"
        ticket_dir.mkdir()
        (ticket_dir / "ticket.json").write_text(json.dumps({"id": f"ticket-{i:04d}"}))


# ---------------------------------------------------------------------------
# Tests: _count_open_tickets helper
# ---------------------------------------------------------------------------


def test_count_open_tickets_returns_zero_when_dir_missing(tmp_path, cli):
    """_count_open_tickets returns 0 when the tickets directory does not exist."""
    missing = tmp_path / "nonexistent"
    assert cli._count_open_tickets(missing) == 0


def test_count_open_tickets_counts_dirs_with_json(tmp_path, cli):
    """_count_open_tickets counts only subdirs that contain at least one JSON file."""
    tickets_dir = tmp_path / "tickets"
    _make_ticket_dirs(tickets_dir, 5)
    # Add an empty subdir (should not be counted)
    (tickets_dir / "empty-dir").mkdir()
    # Add a non-dir file (should not be counted)
    (tickets_dir / "README.txt").write_text("not a dir")
    assert cli._count_open_tickets(tickets_dir) == 5


# ---------------------------------------------------------------------------
# Tests: --parity-check flag via cmd_summary
# ---------------------------------------------------------------------------


def test_parity_check_pass_when_counts_match(tmp_path, cli, capsys):
    """PARITY: PASS is printed when live count equals health record total (exact match)."""
    health_dir = tmp_path / "health"
    _write_health_record(health_dir, _HEALTH_RECORD)

    tickets_dir = tmp_path / "tickets"
    # health_total = 2+5+3+0 = 10; create exactly 10 ticket dirs
    _make_ticket_dirs(tickets_dir, 10)

    args = argparse.Namespace(
        health_dir=str(health_dir),
        command="summary",
        parity_check=True,
        tickets_dir=str(tickets_dir),
    )
    rc = cli.cmd_summary(args)

    captured = capsys.readouterr()
    assert rc == 0
    assert "PARITY: PASS" in captured.out


def test_parity_check_pass_within_5pct_tolerance(tmp_path, cli, capsys):
    """PARITY: PASS is printed when live count is within 5% tolerance of health total."""
    health_dir = tmp_path / "health"
    _write_health_record(health_dir, _HEALTH_RECORD)

    tickets_dir = tmp_path / "tickets"
    # health_total = 10; tolerance = max(1, int(10*0.05)) = 1
    # 10 - 1 = 9 is within tolerance
    _make_ticket_dirs(tickets_dir, 9)

    args = argparse.Namespace(
        health_dir=str(health_dir),
        command="summary",
        parity_check=True,
        tickets_dir=str(tickets_dir),
    )
    rc = cli.cmd_summary(args)

    captured = capsys.readouterr()
    assert rc == 0
    assert "PARITY: PASS" in captured.out


def test_parity_check_drift_when_counts_differ_beyond_tolerance(tmp_path, cli, capsys):
    """PARITY: DRIFT is printed when live count differs from health total beyond 5%."""
    health_dir = tmp_path / "health"
    _write_health_record(health_dir, _HEALTH_RECORD)

    tickets_dir = tmp_path / "tickets"
    # health_total = 10; tolerance = 1; live=15 → |10-15|=5 > 1 → DRIFT
    _make_ticket_dirs(tickets_dir, 15)

    args = argparse.Namespace(
        health_dir=str(health_dir),
        command="summary",
        parity_check=True,
        tickets_dir=str(tickets_dir),
    )
    rc = cli.cmd_summary(args)

    captured = capsys.readouterr()
    assert rc == 0
    assert "PARITY: DRIFT" in captured.out
    assert "health_total=10" in captured.out
    assert "live_total=15" in captured.out
    assert "delta=5" in captured.out


def test_parity_check_not_printed_when_flag_absent(tmp_path, cli, capsys):
    """No PARITY line is printed when --parity-check flag is not set."""
    health_dir = tmp_path / "health"
    _write_health_record(health_dir, _HEALTH_RECORD)

    args = argparse.Namespace(
        health_dir=str(health_dir),
        command="summary",
        parity_check=False,
        tickets_dir=str(tmp_path / "tickets"),
    )
    rc = cli.cmd_summary(args)

    captured = capsys.readouterr()
    assert rc == 0
    assert "PARITY" not in captured.out


def test_parity_check_via_argv(tmp_path, cli, capsys):
    """Running main() with --parity-check and --tickets-dir produces PARITY output."""
    health_dir = tmp_path / "health"
    _write_health_record(health_dir, _HEALTH_RECORD)

    tickets_dir = tmp_path / "tickets"
    _make_ticket_dirs(tickets_dir, 10)

    rc = cli.main(
        [
            f"--health-dir={health_dir}",
            "summary",
            "--parity-check",
            f"--tickets-dir={tickets_dir}",
        ]
    )

    captured = capsys.readouterr()
    assert rc == 0
    assert "PARITY: PASS" in captured.out
