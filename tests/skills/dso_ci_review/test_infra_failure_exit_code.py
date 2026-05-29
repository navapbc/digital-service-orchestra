"""R4 (PR-C): infrastructure-failure exit-code differentiation.

The runner's main() previously returned ``1`` for both kinds of failure:
  - "review found problems" (real critical/important findings in the diff)
  - "infrastructure failure" (specialist crash, all-synthetic findings,
    runner-level exception)

R4 introduces exit code ``4`` for the infrastructure-failure cases so
the CI workflow's classify step can annotate the run accurately and
operators don't waste time hunting for a code defect when the actual
issue is an LLM-pipeline failure.

Config-gated via ``DSO_INFRA_EXIT_CODE_ENABLED`` (default 1 / true) so a
rollback is a single env-var flip if the classify step has a bug.
"""

from __future__ import annotations

import importlib
from unittest.mock import patch


def _reload_runner():
    """Re-import runner.py so the module-level _infra_failure_exit_code()
    helper picks up the current process env. Tests mutate environment via
    patch.dict, but the helper reads os.environ at call time, so a simple
    import is enough — no reload required. This function exists for
    parity with other tests that may need to re-import on flag change.
    """
    import dso_ci_review.runner as _runner_mod
    return _runner_mod


def test_infra_failure_exit_code_default_returns_4() -> None:
    """With the flag unset, the helper returns 4 (the new default behavior)."""
    runner_mod = _reload_runner()

    with patch.dict("os.environ", {}, clear=False):
        # Ensure the flag is unset for this assertion.
        import os as _os
        _os.environ.pop("DSO_INFRA_EXIT_CODE_ENABLED", None)
        assert runner_mod._infra_failure_exit_code() == 4


def test_infra_failure_exit_code_flag_enabled_returns_4() -> None:
    runner_mod = _reload_runner()

    for truthy in ("1", "true", "True", "TRUE"):
        with patch.dict("os.environ", {"DSO_INFRA_EXIT_CODE_ENABLED": truthy}):
            assert runner_mod._infra_failure_exit_code() == 4, (
                f"truthy value {truthy!r} should enable exit 4"
            )


def test_infra_failure_exit_code_flag_disabled_returns_1() -> None:
    """Rollback path: flag=0 returns 1 (legacy behavior).

    The classify-step rollout is decoupled from this rollback so the
    runner can be unflipped without redeploying ci.yml.
    """
    runner_mod = _reload_runner()

    for falsy in ("0", "false", "False", "FALSE", "no", ""):
        with patch.dict("os.environ", {"DSO_INFRA_EXIT_CODE_ENABLED": falsy}):
            assert runner_mod._infra_failure_exit_code() == 1, (
                f"falsy value {falsy!r} should fall back to exit 1"
            )


def test_infra_failure_exit_code_unknown_value_defaults_to_4() -> None:
    """An unrecognized value should not silently revert to legacy.

    Operators may misconfigure the flag. Defaulting to 4 (new behavior)
    rather than 1 (legacy) means a typo doesn't silently mask the
    classify-step's diagnostic value.
    """
    runner_mod = _reload_runner()

    with patch.dict("os.environ", {"DSO_INFRA_EXIT_CODE_ENABLED": "maybe"}):
        assert runner_mod._infra_failure_exit_code() == 4
