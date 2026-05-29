"""RED tests for runner._run_cluster's per-cluster findings shape guard.

Bug 7f55-d357-dbf6-43b5: CI llm-review Strategy F (multi-cluster aggregated
review) crashes with `AttributeError: 'str' object has no attribute 'get'`
when a per-cluster LLM result has the shape `{"findings": "<string>"}`
instead of `{"findings": [dict, dict, ...]}`. The crash happens inside
``aggregator._deduplicate_findings`` (the per-item ``.get("severity", "")``
call) because ``runner._run_cluster`` blindly calls
``list.extend(dr.get("findings", []))`` — if ``findings`` is a string,
``extend`` flattens it character-by-character into single-character
"findings" that then crash the first ``.get()`` call in dedup.

These tests verify the producer-side type guard inside
``runner._run_cluster``: when a per-cluster dispatch result has
``findings`` of any non-list type (string, int, dict, None, …), the
offending entry MUST be skipped (not flattened) and the cluster MUST
still return a valid result.

Testing mode: RED — fails on `main` (the guard does not exist); passes
after the isinstance(list) guard is added to _run_cluster.

CI evidence: run 26614994184 job 78430031201 (PR #446), log line
`ERROR: LLM call failed: 'str' object has no attribute 'get'`.

Note on code references: this docstring deliberately names functions
and modules (``runner._run_cluster``, ``aggregator._deduplicate_findings``)
rather than file:line citations, because line numbers shift the moment
the fix lands. The fix sites are pinpointed by name in the commit
message; readers needing exact lines should ``git grep`` the symbol.
"""

from __future__ import annotations

import asyncio
from unittest.mock import patch

import pytest

from dso_ci_review.aggregator import _deduplicate_findings
from dso_ci_review.dispatch_ratelimit import DispatchContext
from dso_ci_review.runner import _run_cluster


def _make_spec(cluster_dir: str = "dir-0", files: list[str] | None = None) -> dict:
    return {
        "cluster_dir": cluster_dir,
        "files": files or ["file_0.py"],
        "diff": "diff",
        "oversized_single_file": False,
    }


def _make_tier_agents(n: int = 1) -> list[dict]:
    return [
        {"agent_id": f"specialist-{i}", "model": "claude-sonnet-4-5", "tier": "light"}
        for i in range(n)
    ]


async def _run_one(dispatch_results_value):
    """Drive _run_cluster once with a mocked async_dispatch_specialists
    that returns dispatch_results_value verbatim."""

    async def _fake_dispatch(agents, *, dispatch_context=None):
        return dispatch_results_value

    spec = _make_spec()
    tier_agents = _make_tier_agents(1)
    ctx = DispatchContext.create()
    sem = asyncio.Semaphore(1)
    with patch(
        "dso_ci_review.runner.async_dispatch_specialists",
        new=_fake_dispatch,
    ):
        return await _run_cluster(
            spec=spec,
            tier_agents=tier_agents,
            sem=sem,
            dispatch_ctx=ctx,
            cluster_index=0,
            cycle_number=2,
            diff_text_fallback="",
        )


def test_string_findings_value_is_not_extended_char_by_char():
    """A degraded LLM response like {"findings": "no issues found"} MUST NOT
    be flattened into single-character entries via list.extend(str)."""

    degraded = [{"findings": "no issues found"}]
    result = asyncio.run(_run_one(degraded))

    assert isinstance(result, dict), "cluster must always return a dict"
    findings = result.get("findings")
    assert isinstance(findings, list), "findings field must be a list"
    # CHARACTER FLATTENING DETECTION: list.extend("no issues found") would
    # produce ['n', 'o', ' ', 'i', 's', ...]. None of those are dicts.
    for f in findings:
        assert isinstance(f, dict), (
            f"per-cluster findings must be dicts; got {type(f).__name__}: {f!r}. "
            "If this fires, list.extend was called on a string and flattened "
            "it character-by-character — the isinstance(list) guard inside "
            "runner._run_cluster regressed."
        )


@pytest.mark.parametrize(
    "bad_value",
    [
        "no issues found",                       # string
        42,                                      # int
        None,                                    # None
        {"nested": "dict"},                      # dict (not a list of dicts)
        ("findings", "as", "tuple"),             # tuple
    ],
)
def test_non_list_findings_value_is_skipped(bad_value):
    """Any non-list findings value MUST be skipped without raising and
    without contaminating the result list."""

    degraded = [{"findings": bad_value}]
    result = asyncio.run(_run_one(degraded))

    assert isinstance(result, dict)
    findings = result.get("findings")
    assert isinstance(findings, list)
    # Either empty or contains only valid dicts (the degraded entry is dropped).
    for f in findings:
        assert isinstance(f, dict)


def test_mixed_valid_and_degraded_yields_only_valid():
    """When one dispatch result is degraded (string findings) and another is
    valid (list of dicts), the valid findings MUST still be returned and the
    degraded entry MUST NOT contaminate them."""

    mixed = [
        {"findings": "degraded response"},       # bad
        {"findings": [{"severity": "important", "description": "real"}]},  # good
    ]
    result = asyncio.run(_run_one(mixed))

    findings = result.get("findings", [])
    # The real finding must be present.
    assert any(
        isinstance(f, dict) and f.get("description") == "real" for f in findings
    ), f"expected the real finding to survive; got {findings!r}"
    # No char-fragments must be present.
    for f in findings:
        assert isinstance(f, dict), f"non-dict leaked into findings: {f!r}"


def test_well_formed_findings_unchanged_happy_path():
    """The fix MUST NOT regress the happy path: a valid list of findings
    must still be returned unchanged."""

    valid = [
        {"findings": [
            {"severity": "important", "description": "first"},
            {"severity": "minor", "description": "second"},
        ]},
    ]
    result = asyncio.run(_run_one(valid))

    findings = result.get("findings", [])
    assert len(findings) == 2
    assert findings[0]["description"] == "first"
    assert findings[1]["description"] == "second"


def test_run_cluster_output_does_not_crash_deduplicate_findings():
    """End-to-end: feeding _run_cluster's output (with a degraded upstream
    response) into _deduplicate_findings MUST NOT raise AttributeError.
    This is the exact crash observed on PR #446 run 26614994184."""

    degraded = [
        {"findings": "no issues found"},
        {"findings": [{"severity": "important", "description": "real",
                       "cited_lines": [1, 2]}]},
    ]
    result = asyncio.run(_run_one(degraded))

    # The downstream consumer is aggregator._deduplicate_findings. It must
    # not raise — this is the exact crash on PR #446.
    try:
        deduped = _deduplicate_findings(result["findings"])
    except AttributeError as exc:
        pytest.fail(
            "regression of bug 7f55: _deduplicate_findings raised "
            f"AttributeError: {exc}. The cluster result contained a "
            "non-dict entry that crashed the .get() call inside "
            "aggregator._deduplicate_findings. The producer-side guard "
            "inside runner._run_cluster must reject non-list "
            "findings values."
        )

    # And the real finding must survive dedup.
    assert any(
        d.get("description") == "real" for d in deduped
    ), f"expected real finding to survive dedup; got {deduped!r}"
