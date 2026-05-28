"""Test for runner.main()'s CLI-only invariant — must-fix 2 from Phase 1 review.

main() must refuse to run inside an existing event loop because its
asyncio.run() invocations assume they own the loop. If a future host
integration tries to embed main() in a running loop, this assertion fires
and points the maintainer at the documented option (subprocess).
"""
from __future__ import annotations

import asyncio

import pytest

from dso_ci_review.runner import main


def test_main_refuses_running_loop():
    """Calling main() from inside an asyncio event loop should raise."""

    async def _attempt():
        return main()

    with pytest.raises(RuntimeError, match="CLI-only"):
        asyncio.run(_attempt())


def test_main_runs_in_plain_context():
    """Outside any loop, main() reaches its CLI body. Use the dry-run env
    var so it short-circuits without performing real LLM dispatch."""
    import os

    os.environ["DSO_CI_REVIEW_DRY_RUN"] = "1"
    try:
        rc = main()
    finally:
        del os.environ["DSO_CI_REVIEW_DRY_RUN"]
    assert rc == 0
