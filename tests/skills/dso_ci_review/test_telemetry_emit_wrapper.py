"""Tests for dso_ci_review.telemetry_emit_wrapper.

TDD: written BEFORE the implementation. All tests should fail (RED) until
telemetry_emit_wrapper.py is created and wired.

Test matrix:
  1. test_emit_event_invokes_popen — Popen called with telemetry-emit.sh + --event-type
  2. test_emit_event_fire_and_forget — no .wait()/.communicate() called; DEVNULL kwargs set
  3. test_emit_event_oserror_silent — OSError from Popen swallowed, returns None
  4. test_emit_event_returns_event_id_when_key_given — returns UUID-like string with key=
  5. test_emit_event_link_resolves_to_keyed_event_id — --event-id-link <id> passed
  6. test_emit_event_latency_under_100ms — wall clock of 5 calls w/ patched Popen < 100ms
  7. test_dso_telemetry_disable_is_noop — DSO_TELEMETRY_DISABLE=1 → Popen never called
  8. test_fire_and_forget_no_zombies_after_atexit — atexit handler reaps completed children
"""

from __future__ import annotations

import subprocess
import sys
import time
import pathlib
import uuid
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Path setup: ensure dso_ci_review package from the plugin is importable.
# conftest.py in this directory handles this via _ensure_plugin_package(), but
# we also guard here so the module path is on sys.path for direct invocations.
# ---------------------------------------------------------------------------
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)


# Deferred import — module does not exist yet during RED phase.
def _import_wrapper():
    from dso_ci_review import telemetry_emit_wrapper  # noqa: PLC0415

    return telemetry_emit_wrapper


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_mock_proc(returncode=0):
    """Return a mock Popen process object with .poll() returning returncode."""
    proc = MagicMock()
    proc.returncode = returncode
    proc.poll.return_value = returncode
    return proc


# ---------------------------------------------------------------------------
# Test 1: emit_event invokes subprocess.Popen with telemetry-emit.sh + --event-type
# ---------------------------------------------------------------------------


def test_emit_event_invokes_popen(monkeypatch):
    """emit_event() must call subprocess.Popen exactly once.

    The argv must include the path to telemetry-emit.sh and --event-type <event_type>.
    """
    mod = _import_wrapper()
    mock_proc = _make_mock_proc()

    with patch("subprocess.Popen", return_value=mock_proc) as mock_popen:
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        mod.emit_event("review_finding", severity="minor")

    mock_popen.assert_called_once()
    argv = mock_popen.call_args[0][0]
    assert any("telemetry-emit.sh" in str(a) for a in argv), (
        f"telemetry-emit.sh not found in argv: {argv}"
    )
    assert "--event-type" in argv
    assert "review_finding" in argv


# ---------------------------------------------------------------------------
# Test 2: fire-and-forget — no .wait() / .communicate() called; DEVNULL kwargs
# ---------------------------------------------------------------------------


def test_emit_event_fire_and_forget(monkeypatch):
    """emit_event() must not call .wait() or .communicate() on the child process.

    DEVNULL must be passed for stdin, stdout, and stderr. close_fds and
    start_new_session must be True.
    """
    mod = _import_wrapper()
    mock_proc = _make_mock_proc()

    with patch("subprocess.Popen", return_value=mock_proc) as mock_popen:
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        mod.emit_event("tool_finding")

    # .wait() and .communicate() must NOT have been called
    mock_proc.wait.assert_not_called()
    mock_proc.communicate.assert_not_called()

    # Check DEVNULL kwargs
    kwargs = mock_popen.call_args[1]
    assert kwargs.get("stdin") == subprocess.DEVNULL, "stdin must be DEVNULL"
    assert kwargs.get("stdout") == subprocess.DEVNULL, "stdout must be DEVNULL"
    assert kwargs.get("stderr") == subprocess.DEVNULL, "stderr must be DEVNULL"
    assert kwargs.get("close_fds") is True, "close_fds must be True"
    assert kwargs.get("start_new_session") is True, "start_new_session must be True"


# ---------------------------------------------------------------------------
# Test 3: OSError from Popen is swallowed, returns None
# ---------------------------------------------------------------------------


def test_emit_event_oserror_silent(monkeypatch):
    """OSError raised by Popen must be swallowed; emit_event returns None without raising."""
    mod = _import_wrapper()

    with patch("subprocess.Popen", side_effect=OSError("no such file")):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        result = mod.emit_event("review_cycle")

    assert result is None


# ---------------------------------------------------------------------------
# Test 4: returns event_id (UUID-like string) when key= is given
# ---------------------------------------------------------------------------


def test_emit_event_returns_event_id_when_key_given(monkeypatch):
    """emit_event(..., key='k1') must return a UUID4-like string."""
    mod = _import_wrapper()
    mock_proc = _make_mock_proc()

    with patch("subprocess.Popen", return_value=mock_proc):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        result = mod.emit_event("review_finding", key="k1")

    assert result is not None, "Must return event_id when key= is given"
    # Validate UUID4 shape: 8-4-4-4-12 hex groups
    try:
        parsed = uuid.UUID(result, version=4)
        assert str(parsed) == result
    except (ValueError, AttributeError):
        pytest.fail(f"Returned value {result!r} is not a valid UUID4")


# ---------------------------------------------------------------------------
# Test 5: link= resolves to previously keyed event_id
# ---------------------------------------------------------------------------


def test_emit_event_link_resolves_to_keyed_event_id(monkeypatch):
    """emit_event with link= should pass --event-id-link <id> where <id> matches the
    event_id returned by the earlier emit_event with key=.
    """
    mod = _import_wrapper()
    mock_proc = _make_mock_proc()

    captured_argv_calls: list[list] = []

    def capture_popen(argv, **kwargs):
        captured_argv_calls.append(list(argv))
        return mock_proc

    with patch("subprocess.Popen", side_effect=capture_popen):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        # Emit with key, capture returned event_id
        event_id = mod.emit_event("review_finding", key="link-test-key")
        assert event_id is not None

        # Emit with link referencing the same key
        mod.emit_event("resolver_outcome", link="link-test-key")

    assert len(captured_argv_calls) == 2, (
        f"Expected 2 Popen calls, got {len(captured_argv_calls)}"
    )

    # Second call must include --event-id-link <event_id>
    second_argv = captured_argv_calls[1]
    assert "--event-id-link" in second_argv, (
        f"--event-id-link not found in second Popen argv: {second_argv}"
    )
    link_idx = second_argv.index("--event-id-link")
    assert second_argv[link_idx + 1] == event_id, (
        f"--event-id-link value {second_argv[link_idx + 1]!r} != event_id {event_id!r}"
    )


# ---------------------------------------------------------------------------
# Test 6: wall-clock latency under 100ms for 5 sequential emits (patched Popen)
# ---------------------------------------------------------------------------


def test_emit_event_latency_under_100ms(monkeypatch):
    """5 sequential emit_event() calls with patched Popen must complete under 100ms total.

    This validates that the hot path does not block on subprocess I/O.
    """
    mod = _import_wrapper()
    mock_proc = _make_mock_proc()

    with patch("subprocess.Popen", return_value=mock_proc):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        start = time.monotonic()
        for _ in range(5):
            mod.emit_event("review_finding", key=f"latency-test-{_}")
        elapsed_ms = (time.monotonic() - start) * 1000

    assert elapsed_ms < 100, (
        f"5 sequential emit_event() calls took {elapsed_ms:.1f}ms — exceeds 100ms ceiling"
    )


# ---------------------------------------------------------------------------
# Test 7: DSO_TELEMETRY_DISABLE=1 is a hard no-op
# ---------------------------------------------------------------------------


def test_dso_telemetry_disable_is_noop(monkeypatch):
    """When DSO_TELEMETRY_DISABLE=1 is set, emit_event must not invoke Popen at all."""
    mod = _import_wrapper()

    with patch("subprocess.Popen") as mock_popen:
        monkeypatch.setenv("DSO_TELEMETRY_DISABLE", "1")
        result = mod.emit_event("review_cycle")

    mock_popen.assert_not_called()
    assert result is None


# ---------------------------------------------------------------------------
# Test 8: atexit handler reaps completed children (no zombies)
# ---------------------------------------------------------------------------


def test_fire_and_forget_no_zombies_after_atexit(monkeypatch):
    """After atexit handler runs, spawned child processes should be reaped.

    We spawn 3 mock Popen objects, simulate atexit, and verify that .poll()
    was called on each (the reaper's cleanup mechanism).
    """
    mod = _import_wrapper()
    mock_procs = [_make_mock_proc(returncode=0) for _ in range(3)]
    proc_iter = iter(mock_procs)

    def next_proc(argv, **kwargs):
        return next(proc_iter)

    with patch("subprocess.Popen", side_effect=next_proc):
        monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=False)
        for i in range(3):
            mod.emit_event("review_finding", key=f"zombie-test-{i}")

    # Simulate the atexit handler (call it directly)
    if hasattr(mod, "_atexit_reap_children"):
        mod._atexit_reap_children()
    else:
        # Fall back: trigger any registered atexit functions in the module
        # by calling _reap_all_children or similar
        reaper = getattr(mod, "_reap_children", None) or getattr(
            mod, "_atexit_handler", None
        )
        if reaper is not None:
            reaper()

    # Each mock proc should have had .poll() called (the reaper's mechanism)
    for proc in mock_procs:
        assert proc.poll.called, (
            f"Mock process {proc} was not polled by the atexit reaper"
        )
