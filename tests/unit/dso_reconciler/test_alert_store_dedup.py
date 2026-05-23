"""Tests for alert_store.py — JSONL append and 24h UTC-boundary dedup readback."""
from __future__ import annotations

import json
import time

import pytest

from plugins.dso.scripts.dso_reconciler import alert_store


def _write_record(path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")


# ---------------------------------------------------------------------------
# Test (a): in-window same-key entry returns is_deduped=True
# ---------------------------------------------------------------------------


def test_in_window_same_key_is_deduped(tmp_path):
    """A record written within the 24h window for a given key is detected."""
    store_dir = tmp_path / "bridge_state" / "bridge_alerts"
    store_dir.mkdir(parents=True)
    record = {
        "key": "alert-key-abc",
        "timestamp_ns": time.time_ns(),
        "resolved": False,
    }
    today_file = store_dir / "2099-01-01.jsonl"
    _write_record(today_file, record)

    result = alert_store.is_deduped("alert-key-abc", tmp_path)

    assert result is True


# ---------------------------------------------------------------------------
# Test (b): UTC-date-boundary — stale timestamps (>24h) return False
# ---------------------------------------------------------------------------


def test_stale_timestamp_not_deduped(tmp_path):
    """A record older than 24h does NOT trigger dedup, even if the file is globbed."""
    store_dir = tmp_path / "bridge_state" / "bridge_alerts"
    store_dir.mkdir(parents=True)
    # Write a record with a timestamp 25 hours in the past
    stale_ts = time.time_ns() - (25 * 3600 * 1_000_000_000)
    record = {
        "key": "stale-key",
        "timestamp_ns": stale_ts,
        "resolved": False,
    }
    yesterday_file = store_dir / "2099-01-01.jsonl"
    _write_record(yesterday_file, record)

    result = alert_store.is_deduped("stale-key", tmp_path)

    assert result is False


# ---------------------------------------------------------------------------
# Test (c): missing JSONL directory returns False without raising
# ---------------------------------------------------------------------------


def test_missing_directory_returns_false(tmp_path):
    """is_deduped returns False gracefully when the store directory doesn't exist."""
    # Do NOT create the alerts directory
    result = alert_store.is_deduped("any-key", tmp_path)

    assert result is False


# ---------------------------------------------------------------------------
# Test (d): malformed JSONL line is skipped without aborting
# ---------------------------------------------------------------------------


def test_malformed_jsonl_line_skipped(tmp_path):
    """Malformed JSONL lines are silently skipped; valid lines still processed."""
    store_dir = tmp_path / "bridge_state" / "bridge_alerts"
    store_dir.mkdir(parents=True)
    today_file = store_dir / "2099-01-01.jsonl"

    # Write a malformed line followed by a valid record
    today_file.write_text(
        "this is not valid json\n"
        + json.dumps(
            {
                "key": "good-key",
                "timestamp_ns": time.time_ns(),
                "resolved": False,
            }
        )
        + "\n",
        encoding="utf-8",
    )

    # The malformed line should not abort; the valid record should be found
    result = alert_store.is_deduped("good-key", tmp_path)

    assert result is True


# ---------------------------------------------------------------------------
# Test (e): follow-up op='bug_filed' record patches original entry's bug_ticket_id
# ---------------------------------------------------------------------------


def test_patch_bug_filed_updates_record(tmp_path):
    """patch_bug_filed patches the latest unresolved record for a key in-place."""
    store_dir = tmp_path / "bridge_state" / "bridge_alerts"
    store_dir.mkdir(parents=True)
    today_file = store_dir / "2099-01-01.jsonl"

    original = {
        "key": "patch-key",
        "timestamp_ns": time.time_ns(),
        "resolved": False,
    }
    _write_record(today_file, original)

    alert_store.patch_bug_filed("patch-key", "bug-ticket-999", tmp_path)

    # Read back the patched record
    lines = today_file.read_text(encoding="utf-8").splitlines()
    patched = json.loads(lines[0])

    assert patched["bug_ticket_id"] == "bug-ticket-999"
    assert patched["op"] == "bug_filed"
    assert patched["key"] == "patch-key"
