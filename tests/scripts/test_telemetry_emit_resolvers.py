"""RED tests for telemetry_emit._resolve_<field>() x 11 resolvers.

These tests are RED — they import from plugins/dso/scripts/telemetry/telemetry_emit.py
which does not exist yet. All test functions MUST fail with ImportError at RED commit.
Do NOT use pytest.mark.xfail; the canonical RED mechanism is the ImportError itself.

11 resolvers × 2 tests each (primary source + fallback/default):
1. _resolve_schema_version   — always returns int 1
2. _resolve_event_id         — returns UUIDv4 string
3. _resolve_event_type       — accepts 5 canonical values; raises on unknown
4. _resolve_client_id        — returns config string; raises ValueError on empty
5. _resolve_tool_id          — returns config string
6. _resolve_tool_version     — returns config string
7. _resolve_timestamp        — returns ISO-8601 UTC string
8. _resolve_pr_number        — CI env (GITHUB_PR_NUMBER) → int; absent → None
9. _resolve_commit_sha       — CI env (GITHUB_SHA) → str; absent → git HEAD SHA
10. _resolve_cycle           — explicit arg → int; missing → 1
11. _resolve_language        — explicit arg → str; missing → auto-detect heuristic

Schema source: plugins/dso/docs/contracts/telemetry-event-schema.md
Story: 6d14-1052-0da5-43b1  Task: 7fff-f993-f995-48d1

Run: python -m pytest tests/scripts/test_telemetry_emit_resolvers.py
Expected result before implementation: ImportError/ModuleNotFoundError (RED state).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading — add telemetry/ sub-directory to sys.path so that a plain
# `import telemetry_emit` raises ModuleNotFoundError in RED phase (canonical
# RED mechanism: ImportError/ModuleNotFoundError when module does not exist).
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
_TELEMETRY_DIR = REPO_ROOT / "plugins" / "dso" / "scripts" / "telemetry"

# Insert the telemetry directory on sys.path so Python attempts a real import.
# When the file does not exist this raises ModuleNotFoundError (subclass of
# ImportError), which is the canonical RED failure mode for this test file.
if str(_TELEMETRY_DIR) not in sys.path:
    sys.path.insert(0, str(_TELEMETRY_DIR))

# This import is intentionally at module scope. It raises ModuleNotFoundError
# (a subclass of ImportError) in the RED phase when telemetry_emit.py does not
# exist, causing all 22 tests to fail with collection-time ImportError.
import telemetry_emit as _te  # noqa: E402  (module-level import after path setup)


@pytest.fixture(scope="module")
def mod() -> ModuleType:
    """Return the telemetry_emit module."""
    return _te


# ---------------------------------------------------------------------------
# Helper: UUID v4 pattern
# ---------------------------------------------------------------------------

UUID4_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)

# Five canonical event_type values from the schema contract
CANONICAL_EVENT_TYPES = frozenset(
    [
        "review_finding",
        "resolver_outcome",
        "arbiter_ruling",
        "tool_finding",
        "review_cycle",
    ]
)


# ===========================================================================
# 1. _resolve_schema_version
# ===========================================================================


def test_resolve_schema_version_returns_int_one(mod: ModuleType) -> None:
    """_resolve_schema_version() must return the integer 1, not the string '1'."""
    schema_version = mod._resolve_schema_version()
    assert isinstance(schema_version, int), (
        f"Expected int, got {type(schema_version).__name__}"
    )
    assert schema_version == 1, f"Expected schema_version == 1, got {schema_version}"


def test_resolve_schema_version_not_string(mod: ModuleType) -> None:
    """_resolve_schema_version() must never return a string value."""
    schema_version = mod._resolve_schema_version()
    assert not isinstance(schema_version, str), (
        "_resolve_schema_version() returned a string; schema requires numeric integer 1"
    )


# ===========================================================================
# 2. _resolve_event_id
# ===========================================================================


def test_resolve_event_id_returns_uuidv4(mod: ModuleType) -> None:
    """_resolve_event_id() must return a valid UUID v4 string."""
    result = mod._resolve_event_id()
    assert isinstance(result, str), f"Expected str, got {type(result).__name__}"
    assert UUID4_RE.match(result), (
        f"_resolve_event_id() returned '{result}' which is not a valid UUID v4"
    )


def test_resolve_event_id_unique_on_each_call(mod: ModuleType) -> None:
    """_resolve_event_id() must return a different value on each call (UUID v4 is random)."""
    id1 = mod._resolve_event_id()
    id2 = mod._resolve_event_id()
    assert id1 != id2, (
        "_resolve_event_id() returned the same UUID twice; each call must produce a unique ID"
    )


# ===========================================================================
# 3. _resolve_event_type
# ===========================================================================


def test_resolve_event_type_accepts_canonical_values(mod: ModuleType) -> None:
    """_resolve_event_type() must accept all 5 canonical event type values."""
    for event_type in CANONICAL_EVENT_TYPES:
        result = mod._resolve_event_type(event_type)
        assert result == event_type, (
            f"_resolve_event_type('{event_type}') returned '{result}', expected '{event_type}'"
        )


def test_resolve_event_type_raises_on_unknown_value(mod: ModuleType) -> None:
    """_resolve_event_type() must raise on a value outside the 5-enum set."""
    with pytest.raises((ValueError, KeyError, AssertionError)):
        mod._resolve_event_type("not_a_valid_event_type")


# ===========================================================================
# 4. _resolve_client_id
# ===========================================================================


def test_resolve_client_id_returns_nonempty_string(mod: ModuleType) -> None:
    """_resolve_client_id() returns a non-empty string when config provides one."""
    result = mod._resolve_client_id("c8f2e1a0-4b3d-4c9e-8f1a-2b3c4d5e6f70")
    assert isinstance(result, str), f"Expected str, got {type(result).__name__}"
    assert len(result) > 0, "_resolve_client_id() returned empty string"


def test_resolve_client_id_raises_on_empty(mod: ModuleType) -> None:
    """_resolve_client_id() must raise ValueError when given empty/missing input."""
    with pytest.raises(ValueError):
        mod._resolve_client_id("")


# ===========================================================================
# 7. _resolve_timestamp
# ===========================================================================

ISO8601_UTC_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"
)


def test_resolve_timestamp_returns_iso8601_utc(mod: ModuleType) -> None:
    """_resolve_timestamp() must return an ISO 8601 UTC timestamp string."""
    result = mod._resolve_timestamp()
    assert isinstance(result, str), f"Expected str, got {type(result).__name__}"
    assert ISO8601_UTC_RE.match(result), (
        f"_resolve_timestamp() returned '{result}' which does not match ISO 8601 UTC format"
    )


def test_resolve_timestamp_monotonically_non_decreasing(mod: ModuleType) -> None:
    """Successive _resolve_timestamp() calls must return non-decreasing values."""
    t1 = mod._resolve_timestamp()
    t2 = mod._resolve_timestamp()
    # String comparison is valid for ISO 8601 UTC with consistent format
    assert t1 <= t2, (
        f"Timestamp went backwards: {t1} > {t2}; timestamps must be monotonically non-decreasing"
    )


# ===========================================================================
# 8. _resolve_pr_number
# ===========================================================================


def test_resolve_pr_number_from_ci_env(
    mod: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """_resolve_pr_number() returns int PR number when GITHUB_PR_NUMBER env var is set."""
    monkeypatch.setenv("GITHUB_PR_NUMBER", "279")
    result = mod._resolve_pr_number()
    assert isinstance(result, int), f"Expected int, got {type(result).__name__}"
    assert result == 279, f"Expected 279, got {result}"


def test_resolve_pr_number_returns_none_outside_ci(
    mod: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """_resolve_pr_number() returns None when GITHUB_PR_NUMBER env var is absent."""
    monkeypatch.delenv("GITHUB_PR_NUMBER", raising=False)
    result = mod._resolve_pr_number()
    assert result is None, (
        f"_resolve_pr_number() returned {result!r} outside CI context; expected None"
    )


# ===========================================================================
# 9. _resolve_commit_sha
# ===========================================================================


def test_resolve_commit_sha_from_ci_env(
    mod: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """_resolve_commit_sha() returns the value of GITHUB_SHA when set."""
    fake_sha = "69b5b59240abc123def456abc123def456abc123"
    monkeypatch.setenv("GITHUB_SHA", fake_sha)
    result = mod._resolve_commit_sha()
    assert isinstance(result, str), f"Expected str, got {type(result).__name__}"
    assert result == fake_sha, f"Expected '{fake_sha}', got '{result}'"


def test_resolve_commit_sha_falls_back_to_git_head(
    mod: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """_resolve_commit_sha() falls back to git rev-parse HEAD when GITHUB_SHA is absent."""
    monkeypatch.delenv("GITHUB_SHA", raising=False)
    result = mod._resolve_commit_sha()
    # When git is available the result should be a 40-char hex SHA;
    # when unavailable the resolver may return None (per optional-field schema rule).
    if result is not None:
        assert isinstance(result, str), (
            f"Expected str or None, got {type(result).__name__}"
        )
        assert re.match(r"^[0-9a-f]{40}$", result, re.IGNORECASE), (
            f"_resolve_commit_sha() fallback returned '{result}', "
            "expected 40-char hex SHA or None"
        )


# ===========================================================================
# 10. _resolve_cycle
# ===========================================================================


def test_resolve_cycle_returns_explicit_value(mod: ModuleType) -> None:
    """_resolve_cycle() returns the explicit integer argument when provided."""
    result = mod._resolve_cycle(3)
    assert isinstance(result, int), f"Expected int, got {type(result).__name__}"
    assert result == 3, f"Expected 3, got {result}"


def test_resolve_cycle_defaults_to_one(mod: ModuleType) -> None:
    """_resolve_cycle() returns 1 when no argument is provided."""
    result = mod._resolve_cycle()
    assert isinstance(result, int), f"Expected int, got {type(result).__name__}"
    assert result == 1, f"Expected default cycle=1, got {result}"


# Note: _resolve_tool_id, _resolve_tool_version, and _resolve_language were
# removed as tautological identity wrappers — their values pass through directly
# from config / argv at the call site in main().
