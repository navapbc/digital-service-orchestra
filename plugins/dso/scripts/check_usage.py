#!/usr/bin/env python3
"""Usage-aware throttle verdicts for Claude Code sessions.

Polls the Anthropic OAuth usage endpoint and computes a 3-tier verdict:
  0 = unlimited  (below all thresholds)
  1 = throttled  (5hr >= 90% OR 7day >= 95%)
  2 = paused     (5hr >= 95% OR 7day >= 98%)

Cache contract (JSON written to CACHE_PATH):
    {
        "five_hour_pct": 0.85,         // flattened 5-hour utilization
        "seven_day_pct": 0.72,         // flattened 7-day utilization
        "timestamp": 1234567890,       // epoch seconds at write time
        "resets_at": "2026-04-06T18:00:00Z"  // optional, from API response
    }

TTL semantics: stale cache serves last verdict while a fresh poll is attempted.
"""

from __future__ import annotations

import fcntl
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Module-level constants (mockable via mock.patch.object)
# ---------------------------------------------------------------------------

CACHE_PATH: str = str(Path.home() / ".cache" / "claude" / "usage-cache.json")

_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
_BETA_HEADER = "oauth-2025-04-20"
_DEFAULT_TIMEOUT = 8
_DEFAULT_TTL = 300  # 5 minutes
_TTL_FLOOR = 60  # minimum TTL in seconds


# ---------------------------------------------------------------------------
# Credential retrieval
# ---------------------------------------------------------------------------


def get_oauth_token() -> str | None:
    """Retrieve OAuth access token from platform credential store.

    macOS: security CLI -> Keychain -> claudeAiOauth.accessToken
    Linux: ~/.claude/.credentials.json -> claudeAiOauth.accessToken

    Returns None if credentials are unavailable.
    Never logs/prints the token value.
    """
    if platform.system() == "Darwin":
        return _get_token_macos()
    return _get_token_linux()


def _get_token_macos() -> str | None:
    """Read OAuth token from macOS Keychain via security CLI."""
    try:
        raw = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                "Claude Code-credentials",
                "-w",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if raw.returncode != 0 or not raw.stdout.strip():
            return None
        creds = json.loads(raw.stdout.strip())
        token = creds.get("claudeAiOauth", {}).get("accessToken")
        return token if token else None
    except (json.JSONDecodeError, subprocess.TimeoutExpired, FileNotFoundError):
        return None


def _get_token_linux() -> str | None:
    """Read OAuth token from ~/.claude/.credentials.json."""
    creds_path = Path.home() / ".claude" / ".credentials.json"
    try:
        with open(creds_path) as f:
            creds = json.load(f)
        token = creds.get("claudeAiOauth", {}).get("accessToken")
        return token if token else None
    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        return None


# ---------------------------------------------------------------------------
# HTTP polling
# ---------------------------------------------------------------------------


def fetch_usage(token: str, timeout: int = _DEFAULT_TIMEOUT) -> dict:
    """GET usage data from the Anthropic OAuth endpoint.

    Args:
        token: Bearer OAuth access token.
        timeout: HTTP timeout in seconds (default 8).

    Returns:
        Raw API response dict with nested five_hour/seven_day objects.
        write_cache() flattens these to five_hour_pct/seven_day_pct.

    Raises:
        Exception on HTTP errors (including 429) or timeouts.
    """
    req = urllib.request.Request(
        _USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": _BETA_HEADER,
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode())

    # Check for API-level error
    if isinstance(data, dict) and data.get("type") == "error":
        raise Exception(f"API error: {data}")

    # Validate expected nested fields
    _validate_usage_fields(data)

    return data


def _validate_usage_fields(data: dict) -> None:
    """Validate that usage response contains expected nested field types.

    Ensures five_hour and seven_day are dicts with numeric utilization values.
    Coerces missing/invalid fields to safe defaults in-place.
    """
    for key in ("five_hour", "seven_day"):
        bucket = data.get(key)
        if not isinstance(bucket, dict):
            data[key] = {"utilization": 0.0}
            continue
        util = bucket.get("utilization")
        if not isinstance(util, (int, float)):
            bucket["utilization"] = 0.0


# ---------------------------------------------------------------------------
# Cache operations
# ---------------------------------------------------------------------------


def read_cache(cache_path: str) -> dict | None:
    """Read cached usage data from disk.

    Returns:
        Parsed dict if cache file exists and is valid JSON, else None.
    """
    try:
        with open(cache_path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        return None


def _normalize_utilization(v: float) -> float:
    """Normalize utilization to 0.0–1.0 fraction.

    The Anthropic API can return either fractional (0.07 for 7%) or
    whole-number percentages (7.0 for 7%). Divide by 100 when v > 1.0.
    """
    return v / 100.0 if v > 1.0 else v


def write_cache(cache_path: str, data: dict) -> None:
    """Write usage data to cache with atomic rename and flock on separate lock file.

    Creates parent directories and lock file as needed.

    Cache JSON format (flat fields):
        {"five_hour_pct": 0.85, "seven_day_pct": 0.72, "timestamp": <epoch>, "resets_at": ...}
    """
    cache_dir = os.path.dirname(cache_path)
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)

    lock_path = os.path.join(os.path.dirname(cache_path), "usage-cache.lock")

    enriched = {
        "five_hour_pct": _normalize_utilization(
            data.get("five_hour", {}).get("utilization", 0.0)
        ),
        "seven_day_pct": _normalize_utilization(
            data.get("seven_day", {}).get("utilization", 0.0)
        ),
        "timestamp": int(time.time()),
        "resets_at": data.get("resets_at", ""),
    }

    # Acquire exclusive lock on the lock file (context manager ensures close)
    with open(lock_path, "w") as lock_fd:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)

            # Atomic write: temp file + rename
            fd, tmp_path = tempfile.mkstemp(dir=cache_dir or ".", suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as tmp_f:
                    json.dump(enriched, tmp_f)
                os.replace(tmp_path, cache_path)
            except BaseException:
                # Clean up temp file on failure
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                raise
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)


def is_cache_stale(cache_path: str, ttl_seconds: int = _DEFAULT_TTL) -> bool:
    """Check if cache file is older than TTL.

    Args:
        cache_path: Path to the cache JSON file.
        ttl_seconds: Maximum age in seconds. Floor-clamped to 60s.

    Returns:
        True if cache is missing or older than TTL, False if fresh.
    """
    effective_ttl = max(ttl_seconds, _TTL_FLOOR)
    try:
        mtime = os.path.getmtime(cache_path)
    except OSError:
        return True
    return (time.time() - mtime) > effective_ttl


# ---------------------------------------------------------------------------
# Verdict logic
# ---------------------------------------------------------------------------


def compute_verdict(five_hour_pct: float, seven_day_pct: float) -> int:
    """Compute throttle verdict from utilization percentages.

    Thresholds (higher severity wins):
        PAUSED (2):    5hr >= 0.95  OR  7day >= 0.98
        THROTTLED (1): 5hr >= 0.90  OR  7day >= 0.95
        UNLIMITED (0): below all thresholds

    Args:
        five_hour_pct: 5-hour rolling utilization (0.0 - 1.0).
        seven_day_pct: 7-day rolling utilization (0.0 - 1.0).

    Returns:
        Exit code: 0 (unlimited), 1 (throttled), 2 (paused).
    """
    # Check paused first (highest severity)
    if five_hour_pct >= 0.95 or seven_day_pct >= 0.98:
        return 2
    # Check throttled
    if five_hour_pct >= 0.90 or seven_day_pct >= 0.95:
        return 1
    # Unlimited
    return 0


# ---------------------------------------------------------------------------
# Main orchestrator
# ---------------------------------------------------------------------------


def main() -> int:
    """Orchestrate: credentials -> CI fallback -> cache -> poll -> verdict.

    Returns:
        Exit code: 0 (unlimited), 1 (throttled), 2 (paused).
    """
    # Step 1: Get credentials
    token = get_oauth_token()
    if token is None:
        print("USAGE_SOURCE: no-credentials")
        return 0

    cache_path = CACHE_PATH

    # Step 2: Read existing cache (for fallback on errors)
    cached = read_cache(cache_path)

    # Step 3: Check cache freshness — skip poll if cache is fresh
    if cached is not None and not is_cache_stale(cache_path):
        five_hr = cached.get("five_hour_pct", 0.0)
        seven_day = cached.get("seven_day_pct", 0.0)
        verdict = compute_verdict(five_hr, seven_day)
        print("USAGE_SOURCE: cache")
        print(f"USAGE_5HR: {five_hr:.0%}")
        print(f"USAGE_7DAY: {seven_day:.0%}")
        print(f"VERDICT: {verdict}")
        return verdict

    # Step 4: Cache stale or missing — poll the API
    usage_data = None
    poll_error = False

    try:
        usage_data = fetch_usage(token, timeout=_DEFAULT_TIMEOUT)
    except Exception:
        poll_error = True

    # Step 5: Handle poll results
    if poll_error:
        # 429 or other error
        if cached is not None:
            # Serve cached data but degrade unlimited -> throttled (fail-closed)
            five_hr = cached.get("five_hour_pct", 0.0)
            seven_day = cached.get("seven_day_pct", 0.0)
            verdict = compute_verdict(five_hr, seven_day)
            if verdict == 0:
                verdict = 1  # degrade unlimited to throttled
            print("USAGE_SOURCE: cache-degraded")
            print(f"USAGE_5HR: {five_hr:.0%}")
            print(f"USAGE_7DAY: {seven_day:.0%}")
            print(f"VERDICT: {verdict}")
            return verdict
        else:
            # No cache, fail-closed
            print("USAGE_SOURCE: error-no-cache")
            print("VERDICT: 1")
            return 1

    if usage_data is not None:
        # Fresh data — write cache and compute verdict
        try:
            write_cache(cache_path, usage_data)
        except Exception:
            pass  # cache write failure is non-fatal

        five_hr = _normalize_utilization(
            usage_data.get("five_hour", {}).get("utilization", 0.0)
        )
        seven_day = _normalize_utilization(
            usage_data.get("seven_day", {}).get("utilization", 0.0)
        )
    else:
        # Should not reach here, but fail-closed
        print("USAGE_SOURCE: unknown")
        print("VERDICT: 1")
        return 1

    verdict = compute_verdict(five_hr, seven_day)
    print("USAGE_SOURCE: api")
    print(f"USAGE_5HR: {five_hr:.0%}")
    print(f"USAGE_7DAY: {seven_day:.0%}")
    print(f"VERDICT: {verdict}")
    return verdict


if __name__ == "__main__":
    sys.exit(main())
