"""Repo-wide pytest configuration.

Provides an autouse fixture that prevents tests from creating new top-level
entries in REPO_ROOT. Tests that write to disk must use ``tmp_path`` or
another sandboxed location. If a test leaks, the leak is cleaned up and the
test fails with a message naming the new entries.

This guard catches the most common leak shape — relative-path writes from
mis-routed tracker_dir/cwd handling (the failure mode that put
``depends_on/tkt-src3`` at the repo root). It does NOT catch writes that
target an existing top-level dir (e.g. ``plugins/dso/scripts/x.json``); for
that level of guarantee, run ``git status --porcelain`` in CI.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Iterator

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(autouse=True)
def _dso_disable_telemetry_during_tests(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Block live telemetry POSTs across the entire pytest session.

    The d2f9 emit wrapper (telemetry_emit_wrapper.emit_event) honours
    DSO_TELEMETRY_DISABLE=1 as a hard no-op switch. Until this fixture
    existed, tests that imported runner.py / arbiter_processor.py and
    reached the emit code paths would Popen the telemetry-emit.sh shim,
    which POSTs to review_telemetry.endpoint_url. While that endpoint
    was the SCP-blocked Lambda Function URL every POST silently 403'd,
    masking the leak. Once endpoint_url was repointed to the API
    Gateway (bypassing the SCP), every unguarded test run started
    polluting s3://dso-telemetry-review-820258254566/<client_id>/<date>/
    with synthetic records.

    Tests that intentionally exercise the wrapper (e.g.
    test_telemetry_emit_wrapper.py, test_telemetry_schema_contract.py)
    already call ``monkeypatch.delenv("DSO_TELEMETRY_DISABLE", raising=
    False)`` per-test; pytest applies the per-test monkeypatch AFTER
    this autouse fixture, so those overrides continue to work
    unchanged.
    """
    monkeypatch.setenv("DSO_TELEMETRY_DISABLE", "1")


@pytest.fixture(autouse=True)
def _dso_dummy_anthropic_api_key(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Set a dummy ANTHROPIC_API_KEY so tests that exercise dispatch_review
    (or any provider-config-validated path) don't fail with
    ``ConfigError: Missing ANTHROPIC_API_KEY`` when run in a CI job that
    lacks the secret (e.g. Python Skill/Doc Tests, ticket-platform-matrix).

    Without this fixture, every test that reaches the provider-config
    validation step needs its own ``monkeypatch.setenv("ANTHROPIC_API_KEY",
    ...)`` even when the LLM call itself is mocked. Bug f148 PR-A surfaced
    this when its R2 test passed locally (key was set in the shell) but
    failed on CI (no key exposed to the unit-test job).

    Tests that intentionally probe the missing-key path (e.g.
    test_providers_config.py:110) already call
    ``monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)`` per-test;
    pytest applies per-test monkeypatch AFTER autouse fixtures, so those
    overrides continue to work unchanged.

    The dummy key shape (sk-test-…) is non-functional — no real API call
    can succeed with it — so leaking it into a real LLM call (e.g. by
    forgetting to mock litellm) will fail loudly with a 401, not silently
    bill a customer's account.
    """
    monkeypatch.setenv(
        "ANTHROPIC_API_KEY", "sk-test-dummy-key-for-unit-tests"
    )


@pytest.fixture(autouse=True)
def _no_repo_root_leaks() -> Iterator[None]:
    before = set(os.listdir(_REPO_ROOT))
    try:
        yield
    finally:
        after = set(os.listdir(_REPO_ROOT))
        leaked = after - before
        if not leaked:
            return
        for name in leaked:
            target = _REPO_ROOT / name
            if target.is_dir():
                shutil.rmtree(target, ignore_errors=True)
            else:
                try:
                    target.unlink()
                except OSError:
                    # Cleanup is best-effort — pytest.fail() below already
                    # surfaces the leak. Suppressing keeps a permissions or
                    # races race from masking the real failure.
                    pass
        pytest.fail(
            "Test leaked new entries into REPO_ROOT (use tmp_path or a "
            f"sandboxed temp dir): {sorted(leaked)}"
        )
