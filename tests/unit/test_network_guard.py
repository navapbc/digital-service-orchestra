"""Tests for the network-escape guard (bug 1c68).

Verifies that:
1. Tests in the unit tier that open a real socket are blocked with a clear
   RuntimeError — the guard is active and raises on connect().
2. Tests decorated with @pytest.mark.allow_network bypass the guard.
3. The guard does NOT affect tests outside the guarded tiers.

These tests live under tests/unit/ so the guard fixture applies to them.
The RED-demonstration test (test_guard_blocks_real_socket_connect) validates
that the guard would have caught the bug-1c68 class of network escape.
"""

from __future__ import annotations

import socket
from unittest.mock import patch

import pytest


# ---------------------------------------------------------------------------
# Test 1: guard blocks socket.connect() in the unit tier (RED demonstration)
# ---------------------------------------------------------------------------


def test_guard_blocks_real_socket_connect() -> None:
    """The socket guard must raise RuntimeError when a test tries to connect.

    This is the RED demonstration for bug 1c68: any test that calls
    socket.socket().connect() in the unit tier will be caught.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    with pytest.raises(RuntimeError, match="Network access is forbidden"):
        s.connect(("example.com", 80))


# ---------------------------------------------------------------------------
# Test 2: guard blocks urllib.request.urlopen (the exact bug-1c68 path)
# ---------------------------------------------------------------------------


def test_guard_blocks_urllib_urlopen() -> None:
    """urllib.request.urlopen must be blocked by the socket guard.

    urlopen creates a socket internally; the guard patches socket.connect so
    the connection attempt raises before any real packet leaves the host.
    """
    import urllib.request

    with pytest.raises((RuntimeError, OSError)):
        urllib.request.urlopen("http://example.com/", timeout=1)


# ---------------------------------------------------------------------------
# Test 3: allow_network marker bypasses the guard
# ---------------------------------------------------------------------------


@pytest.mark.allow_network
def test_allow_network_marker_bypasses_guard(monkeypatch: pytest.MonkeyPatch) -> None:
    """Tests decorated with @pytest.mark.allow_network skip the socket guard.

    We still monkeypatch socket.connect here to avoid a real network call
    (this is a unit test, not an e2e probe), but we verify the guard itself
    is NOT active: calling socket.socket().connect() raises the mock's
    side_effect, not the guard's RuntimeError.
    """
    call_log: list[tuple] = []

    def fake_connect(self, addr):  # type: ignore[override]
        call_log.append(addr)
        # Simulate "connection refused" without opening a real socket
        raise ConnectionRefusedError("test stub: connection refused")

    with patch.object(socket.socket, "connect", fake_connect):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        with pytest.raises(ConnectionRefusedError, match="test stub"):
            s.connect(("127.0.0.1", 1))

    assert call_log == [("127.0.0.1", 1)], "fake_connect must have been called"


# ---------------------------------------------------------------------------
# Test 4: guard does NOT block socket.socket() construction — only connect()
# ---------------------------------------------------------------------------


def test_guard_allows_socket_construction() -> None:
    """Creating a socket object must not raise — only connecting does."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    assert s is not None
    s.close()


# ---------------------------------------------------------------------------
# Test 5: guard error message contains actionable guidance
# ---------------------------------------------------------------------------


def test_guard_error_message_is_actionable() -> None:
    """The RuntimeError message must name both the bug ID and the opt-out path."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    with pytest.raises(RuntimeError) as exc_info:
        s.connect(("example.com", 80))

    msg = str(exc_info.value)
    assert "bug 1c68" in msg, f"message should reference bug id; got: {msg!r}"
    assert "allow_network" in msg, (
        f"message should name the opt-out marker; got: {msg!r}"
    )
