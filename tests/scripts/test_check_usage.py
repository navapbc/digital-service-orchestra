"""RED unit tests for check_usage module.

Tests cover threshold/verdict logic, cache read/write, TTL enforcement,
credential fallback, HTTP error handling, and token redaction.

All tests MUST fail with ImportError because check_usage.py does not exist yet.
After the GREEN implementation task, all tests must pass.
"""

from __future__ import annotations

import importlib.util
import os
import time
from pathlib import Path
from unittest import mock

import pytest

# ---------------------------------------------------------------------------
# Module import — will raise ImportError (RED) until check_usage.py exists
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"

_module_path = MODULE_DIR / "check_usage.py"
if not _module_path.exists():
    raise ImportError(
        f"check_usage.py not found at {_module_path} (expected — RED phase)"
    )
_spec = importlib.util.spec_from_file_location("check_usage", _module_path)
assert _spec is not None and _spec.loader is not None
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)  # type: ignore[union-attr]

# Expected public API (will be validated when module exists):
#   compute_verdict(five_hour_util: float, seven_day_util: float) -> int
#   read_cache(cache_path: str) -> dict | None
#   write_cache(cache_path: str, data: dict) -> None
#   is_cache_stale(cache_path: str, ttl_seconds: int) -> bool
#   fetch_usage(token: str, timeout: int) -> dict
#   get_oauth_token() -> str | None
#   main() -> int
compute_verdict = _module.compute_verdict  # type: ignore[attr-defined]
read_cache = _module.read_cache  # type: ignore[attr-defined]
write_cache = _module.write_cache  # type: ignore[attr-defined]
is_cache_stale = _module.is_cache_stale  # type: ignore[attr-defined]
fetch_usage = _module.fetch_usage  # type: ignore[attr-defined]
get_oauth_token = _module.get_oauth_token  # type: ignore[attr-defined]
main = _module.main  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# Verdict / threshold tests
# ---------------------------------------------------------------------------


class TestVerdictThresholds:
    """Verify exit code logic based on utilization percentages.

    Thresholds (from epic description):
      PAUSED:    5hr >= 95% OR 7day >= 98%  -> exit 2
      THROTTLED: 5hr >= 90% OR 7day >= 95%  -> exit 1
      UNLIMITED: below all thresholds       -> exit 0
    """

    def test_verdict_unlimited(self) -> None:
        """Utilization below all thresholds -> exit 0."""
        assert compute_verdict(0.50, 0.50) == 0
        assert compute_verdict(0.89, 0.94) == 0
        assert compute_verdict(0.0, 0.0) == 0

    def test_verdict_throttled_5hr(self) -> None:
        """5hr utilization >= 90% (but < 95%) -> exit 1 (throttled)."""
        assert compute_verdict(0.90, 0.50) == 1
        assert compute_verdict(0.94, 0.50) == 1

    def test_verdict_throttled_7day(self) -> None:
        """7day utilization >= 95% (but < 98%) -> exit 1 (throttled)."""
        assert compute_verdict(0.50, 0.95) == 1
        assert compute_verdict(0.50, 0.97) == 1

    def test_verdict_paused_5hr(self) -> None:
        """5hr utilization >= 95% -> exit 2 (paused)."""
        assert compute_verdict(0.95, 0.50) == 2
        assert compute_verdict(1.0, 0.50) == 2

    def test_verdict_paused_7day(self) -> None:
        """7day utilization >= 98% -> exit 2 (paused)."""
        assert compute_verdict(0.50, 0.98) == 2
        assert compute_verdict(0.50, 1.0) == 2

    def test_verdict_paused_takes_precedence(self) -> None:
        """When both paused and throttled thresholds are met, paused (2) wins."""
        assert compute_verdict(0.96, 0.99) == 2


# ---------------------------------------------------------------------------
# Cache tests
# ---------------------------------------------------------------------------


class TestCache:
    """Verify cache read/write, locking, and TTL behavior."""

    def test_cache_write_and_read(self, tmp_path: Path) -> None:
        """Write cache then read -> flat field values match."""
        cache_file = str(tmp_path / "usage-cache.json")
        data = {"five_hour": {"utilization": 0.42}, "seven_day": {"utilization": 0.71}}
        write_cache(cache_file, data)
        result = read_cache(cache_file)
        assert result is not None
        assert result["five_hour_pct"] == pytest.approx(0.42)
        assert result["seven_day_pct"] == pytest.approx(0.71)
        assert "timestamp" in result
        assert "resets_at" in result
        # Verify nested keys are NOT present (flat format)
        assert "five_hour" not in result
        assert "seven_day" not in result

    def test_cache_write_normalizes_whole_number_pct(self, tmp_path: Path) -> None:
        """API utilization values >1.0 (whole-number %) are normalized to 0.0–1.0 fractions.

        The Anthropic API can return utilization as whole-number percentages
        (e.g. 7 for 7%, 77 for 77%) rather than fractions (0.07, 0.77).
        write_cache must normalize values >1.0 by dividing by 100 so that
        verdict thresholds and display formatting remain correct.

        RED: fails before normalization is added to write_cache.
        GREEN: passes after _normalize_utilization is applied in write_cache.
        """
        cache_file = str(tmp_path / "usage-cache.json")
        # API response with whole-number percentage values (7% and 77%)
        data = {"five_hour": {"utilization": 7.0}, "seven_day": {"utilization": 77.0}}
        write_cache(cache_file, data)
        result = read_cache(cache_file)
        assert result is not None
        # Must be stored as fractions, not raw percentages
        assert result["five_hour_pct"] == pytest.approx(0.07), (
            f"Expected five_hour_pct=0.07 (7%/100), got {result['five_hour_pct']} "
            f"(API returned 7.0 which means 7%, not 700%)"
        )
        assert result["seven_day_pct"] == pytest.approx(0.77), (
            f"Expected seven_day_pct=0.77 (77%/100), got {result['seven_day_pct']} "
            f"(API returned 77.0 which means 77%, not 7700%)"
        )
        # Verify verdict is UNLIMITED for 7%/77% usage
        verdict = compute_verdict(result["five_hour_pct"], result["seven_day_pct"])
        assert verdict == 0, (
            f"7%/77% usage should give UNLIMITED (0), got {verdict} "
            f"(normalized pcts: {result['five_hour_pct']}, {result['seven_day_pct']})"
        )

    def test_cache_flock_uses_separate_lockfile(self, tmp_path: Path) -> None:
        """flock is acquired on .lock file, not the .json data file."""
        import fcntl as _fcntl

        cache_file = str(tmp_path / "usage-cache.json")
        lock_file = str(tmp_path / "usage-cache.lock")
        data = {"five_hour": {"utilization": 0.1}, "seven_day": {"utilization": 0.1}}

        flock_calls: list[str] = []
        original_flock = _fcntl.flock

        def tracking_flock(fd: object, operation: int) -> None:
            # Record the path of the file descriptor being locked
            if hasattr(fd, "name"):
                flock_calls.append(fd.name)  # type: ignore[union-attr]
            original_flock(fd, operation)  # type: ignore[arg-type]

        with mock.patch("fcntl.flock", side_effect=tracking_flock):
            write_cache(cache_file, data)

        # The lock file should exist after a write (created during locking)
        assert Path(lock_file).exists(), "Lock file should be created alongside cache"
        # flock must have been called on the .lock file, not the .json file
        assert any(lock_file in call for call in flock_calls), (
            f"flock should target {lock_file}, got calls on: {flock_calls}"
        )

    def test_cache_ttl_expired(self, tmp_path: Path) -> None:
        """Cache older than 5 minutes (300s) is treated as stale."""
        cache_file = str(tmp_path / "usage-cache.json")
        data = {"five_hour": {"utilization": 0.1}, "seven_day": {"utilization": 0.1}}
        write_cache(cache_file, data)
        # Backdate the file modification time by 301 seconds
        old_time = time.time() - 301
        os.utime(cache_file, (old_time, old_time))
        assert is_cache_stale(cache_file, ttl_seconds=300) is True

    def test_cache_ttl_fresh(self, tmp_path: Path) -> None:
        """Cache written just now is NOT stale."""
        cache_file = str(tmp_path / "usage-cache.json")
        data = {"five_hour": {"utilization": 0.1}, "seven_day": {"utilization": 0.1}}
        write_cache(cache_file, data)
        assert is_cache_stale(cache_file, ttl_seconds=300) is False

    def test_cache_ttl_floor(self, tmp_path: Path) -> None:
        """TTL cannot be set below 60 seconds — enforced as floor."""
        cache_file = str(tmp_path / "usage-cache.json")
        data = {"five_hour": {"utilization": 0.1}, "seven_day": {"utilization": 0.1}}
        write_cache(cache_file, data)
        # Backdate by 30s — with floor of 60s, this should NOT be stale
        old_time = time.time() - 30
        os.utime(cache_file, (old_time, old_time))
        # Even though caller requests ttl_seconds=10, floor enforces 60s
        assert is_cache_stale(cache_file, ttl_seconds=10) is False


# ---------------------------------------------------------------------------
# Credential / fallback tests
# ---------------------------------------------------------------------------


class TestCredentialFallback:
    """Verify behavior when OAuth credentials are unavailable."""

    def test_ci_fallback_no_credentials(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """No OAuth token found -> exit 0, output contains USAGE_SOURCE: no-credentials."""
        with mock.patch.object(_module, "get_oauth_token", return_value=None):
            exit_code = main()
        assert exit_code == 0
        captured = capsys.readouterr()
        assert "USAGE_SOURCE: no-credentials" in captured.out


# ---------------------------------------------------------------------------
# HTTP error handling tests
# ---------------------------------------------------------------------------


class TestHTTPErrorHandling:
    """Verify behavior under API errors (429, timeouts)."""

    def test_429_with_cache_degrades(self, tmp_path: Path) -> None:
        """429 response + existing unlimited cache -> degrades to exit 1 (fail-closed)."""
        cache_file = str(tmp_path / "usage-cache.json")
        # Pre-populate cache with unlimited (below-threshold) data
        data = {"five_hour": {"utilization": 0.10}, "seven_day": {"utilization": 0.10}}
        write_cache(cache_file, data)
        # Backdate cache so it's stale (poll will be attempted)
        old_time = time.time() - 400
        os.utime(cache_file, (old_time, old_time))

        with (
            mock.patch.object(_module, "get_oauth_token", return_value="fake-token"),
            mock.patch.object(
                _module, "fetch_usage", side_effect=Exception("HTTP 429")
            ),
            mock.patch.object(_module, "CACHE_PATH", cache_file),
        ):
            exit_code = main()
        # Fail-closed: degrade from unlimited (0) to throttled (1)
        assert exit_code == 1

    def test_429_no_cache(self) -> None:
        """429 response + no cache -> exit 1 (throttled, fail-closed)."""
        with (
            mock.patch.object(_module, "get_oauth_token", return_value="fake-token"),
            mock.patch.object(
                _module, "fetch_usage", side_effect=Exception("HTTP 429")
            ),
            mock.patch.object(_module, "CACHE_PATH", "/nonexistent/cache.json"),
        ):
            exit_code = main()
        assert exit_code == 1

    def test_curl_timeout(self, tmp_path: Path) -> None:
        """Request timeout is set to 8 seconds."""
        cache_file = str(tmp_path / "test-cache.json")
        # Mock urllib/requests to capture the timeout parameter
        fake_token = "fake-token"
        with mock.patch.object(_module, "fetch_usage") as mock_fetch:
            mock_fetch.return_value = {
                "five_hour": {"utilization": 0.1},
                "seven_day": {"utilization": 0.1},
            }
            with (
                mock.patch.object(_module, "get_oauth_token", return_value=fake_token),
                mock.patch.object(_module, "CACHE_PATH", cache_file),
            ):
                main()
        # Verify fetch_usage was called with timeout=8
        mock_fetch.assert_called_once()
        call_kwargs = mock_fetch.call_args
        # The token arg and timeout=8 should be present
        assert call_kwargs is not None
        # Check that 8 appears in the call (positional or keyword)
        args, kwargs = call_kwargs
        assert fake_token in args or kwargs.get("token") == fake_token
        assert 8 in args or kwargs.get("timeout") == 8


# ---------------------------------------------------------------------------
# Security tests
# ---------------------------------------------------------------------------


class TestTokenSecurity:
    """Verify OAuth tokens are never leaked to output."""

    def test_token_not_logged(
        self, capsys: pytest.CaptureFixture[str], tmp_path: Path
    ) -> None:
        """Token value must never appear in stdout or stderr output."""
        cache_file = str(tmp_path / "test-token-log.json")
        secret_token = "sk-ant-oauthsecret-SUPERSECRETVALUE123456789"
        with (
            mock.patch.object(_module, "get_oauth_token", return_value=secret_token),
            mock.patch.object(
                _module,
                "fetch_usage",
                return_value={
                    "five_hour": {"utilization": 0.5},
                    "seven_day": {"utilization": 0.5},
                },
            ),
            mock.patch.object(_module, "CACHE_PATH", cache_file),
        ):
            main()
        captured = capsys.readouterr()
        assert secret_token not in captured.out, "Token leaked to stdout"
        assert secret_token not in captured.err, "Token leaked to stderr"


# ---------------------------------------------------------------------------
# Fresh API path normalization (5c32-6925, 63f3-11a4)
# ---------------------------------------------------------------------------


class TestFreshApiPathNormalization:
    """Fresh API data (not from cache) must normalize whole-number utilization.

    Bug: when fetch_usage returns utilization=49.0 (whole-number %), the
    live-API code path used the raw value directly instead of normalizing via
    _norm(), causing USAGE_5HR to print as 4900% and triggering VERDICT: 2
    (paused) for normal usage sessions.
    """

    def test_whole_number_utilization_from_api_prints_below_100pct(
        self, capsys: pytest.CaptureFixture[str], tmp_path: Path
    ) -> None:
        """API returning whole-number % (49.0 for 49%) must NOT produce USAGE_5HR: 4900%.

        RED: fails before fix because raw value is used without _norm().
        GREEN: passes after _norm() is applied to fresh API data path.
        """
        cache_file = str(tmp_path / "usage-cache.json")
        with (
            mock.patch.object(_module, "get_oauth_token", return_value="fake-token"),
            mock.patch.object(
                _module,
                "fetch_usage",
                return_value={
                    "five_hour": {"utilization": 49.0},
                    "seven_day": {"utilization": 14.0},
                },
            ),
            mock.patch.object(_module, "CACHE_PATH", cache_file),
        ):
            exit_code = main()
        captured = capsys.readouterr()
        assert "USAGE_5HR: 4900%" not in captured.out, (
            "Raw whole-number utilization (49.0) must not print as 4900%"
        )
        assert "USAGE_7DAY: 1400%" not in captured.out, (
            "Raw whole-number utilization (14.0) must not print as 1400%"
        )
        assert "USAGE_5HR: 49%" in captured.out, (
            f"Expected USAGE_5HR: 49%, got: {captured.out}"
        )
        assert exit_code != 2, (
            "Verdict should not be paused (2) for 49% usage — "
            f"exit_code={exit_code}, output={captured.out}"
        )
