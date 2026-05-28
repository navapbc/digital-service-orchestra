"""Tests for Phase 2 cluster-level parallelization in runner._run_cluster.

Validates:
  - Wall-clock parallelism under mocked async_dispatch_specialists (regression
    catcher for a future re-sync of the gather path)
  - Semaphore bounds in-flight count
  - Cycle-1 stagger fires; cycle 2+ skips it
  - Partial failure isolation — one cluster's escape becomes dispatch_error
  - Oversized single-file short-circuits with no dispatch
  - cluster_concurrency config reader honors bounds
"""
from __future__ import annotations

import asyncio
import time
from unittest.mock import patch

import pytest

from dso_ci_review.dispatch_ratelimit import DispatchContext
from dso_ci_review.region_split import _cluster_concurrency
from dso_ci_review.runner import _CYCLE_1_STAGGER_S, _run_cluster


def _make_spec(cluster_dir: str, files: list[str], diff: str = "diff") -> dict:
    return {
        "cluster_dir": cluster_dir,
        "files": files,
        "diff": diff,
        "oversized_single_file": False,
    }


def _make_tier_agents(n: int) -> list[dict]:
    return [
        {"agent_id": f"specialist-{i}", "model": "claude-sonnet-4-5", "tier": "light"}
        for i in range(n)
    ]


SLEEP_S = 0.3


async def _fake_specialist_dispatch(agents, *, dispatch_context=None):
    """Stand-in for async_dispatch_specialists — single asyncio.sleep that
    yields control, so the cluster-level gather observes real parallelism."""
    await asyncio.sleep(SLEEP_S)
    return [
        {"findings": [{"type": "ok", "agent_id": a["agent_id"]}]} for a in agents
    ]


@pytest.mark.parametrize("n_clusters,concurrency", [(2, 2), (4, 2), (5, 3)])
def test_cluster_gather_parallelizes(n_clusters, concurrency):
    """N clusters × SLEEP_S each, run with concurrency C, should take
    ceil(N/C) × SLEEP_S not N × SLEEP_S."""
    specs = [_make_spec(f"dir-{i}", [f"file_{i}.py"]) for i in range(n_clusters)]
    tier_agents = _make_tier_agents(2)

    async def _run() -> tuple[list[dict], float]:
        ctx = DispatchContext.create()
        sem = asyncio.Semaphore(concurrency)
        try:
            t0 = time.monotonic()
            results = await asyncio.gather(
                *[
                    _run_cluster(
                        spec=s,
                        tier_agents=tier_agents,
                        sem=sem,
                        dispatch_ctx=ctx,
                        cluster_index=idx,
                        cycle_number=2,  # skip stagger
                        diff_text_fallback="",
                    )
                    for idx, s in enumerate(specs)
                ],
                return_exceptions=True,
            )
            elapsed = time.monotonic() - t0
            return results, elapsed
        finally:
            ctx.cleanup()

    with patch(
        "dso_ci_review.runner.async_dispatch_specialists",
        side_effect=_fake_specialist_dispatch,
    ):
        results, elapsed = asyncio.run(_run())

    assert len(results) == n_clusters
    assert all(isinstance(r, dict) and r["status"] == "ok" for r in results)
    waves = -(-n_clusters // concurrency)
    expected_lower = SLEEP_S * waves
    expected_upper = SLEEP_S * waves * 1.5
    assert expected_lower <= elapsed <= expected_upper, (
        f"Expected {waves}-wave timing [{expected_lower:.3f}s, {expected_upper:.3f}s], "
        f"got {elapsed:.3f}s for N={n_clusters} C={concurrency}"
    )


def test_oversized_single_file_short_circuits():
    """oversized_single_file spec returns status=oversized_skip without dispatch."""
    spec = {
        "cluster_dir": "huge.py",
        "files": ["huge.py"],
        "diff": "",
        "oversized_single_file": True,
    }
    invocations = {"count": 0}

    async def _should_not_be_called(agents, *, dispatch_context=None):
        invocations["count"] += 1
        return []

    async def _run() -> dict:
        ctx = DispatchContext.create()
        sem = asyncio.Semaphore(1)
        try:
            return await _run_cluster(
                spec=spec,
                tier_agents=_make_tier_agents(2),
                sem=sem,
                dispatch_ctx=ctx,
                cluster_index=0,
                cycle_number=1,
                diff_text_fallback="",
            )
        finally:
            ctx.cleanup()

    with patch(
        "dso_ci_review.runner.async_dispatch_specialists",
        side_effect=_should_not_be_called,
    ):
        result = asyncio.run(_run())

    assert result["status"] == "oversized_skip"
    assert result["cluster_id"] == "huge.py"
    assert result["findings"] == []
    assert invocations["count"] == 0


def test_partial_failure_isolation():
    """One cluster's specialist dispatch raising should not abort the others."""

    async def _maybe_raise(agents, *, dispatch_context=None):
        if agents and agents[0]["agent_id"].endswith("cluster-1"):
            raise RuntimeError("simulated cluster-1 failure")
        await asyncio.sleep(0.05)
        return [{"findings": []} for _ in agents]

    specs = [_make_spec(f"dir-{i}", [f"f{i}"]) for i in range(3)]
    tier_agents = [{"agent_id": "spec-for-cluster-1", "model": "m", "tier": "light"}]

    async def _run():
        ctx = DispatchContext.create()
        sem = asyncio.Semaphore(3)
        try:
            specs_with_marker = []
            for s in specs:
                specs_with_marker.append(s)
            return await asyncio.gather(
                *[
                    _run_cluster(
                        spec=s,
                        tier_agents=[
                            {
                                "agent_id": f"spec-for-cluster-{i}",
                                "model": "m",
                                "tier": "light",
                            }
                        ],
                        sem=sem,
                        dispatch_ctx=ctx,
                        cluster_index=i,
                        cycle_number=2,
                        diff_text_fallback="",
                    )
                    for i, s in enumerate(specs_with_marker)
                ],
                return_exceptions=True,
            )
        finally:
            ctx.cleanup()

    with patch(
        "dso_ci_review.runner.async_dispatch_specialists", side_effect=_maybe_raise
    ):
        results = asyncio.run(_run())

    statuses = [r["status"] for r in results]
    assert statuses == ["ok", "dispatch_error", "ok"], statuses


def test_cycle_1_stagger_fires():
    """cycle_number=1 with cluster_index > 0 should sleep cluster_index × 0.4s."""
    timing = {"start": None, "end": None}

    async def _capture_dispatch(agents, *, dispatch_context=None):
        timing["end"] = time.monotonic()
        return [{"findings": []} for _ in agents]

    async def _run():
        ctx = DispatchContext.create()
        sem = asyncio.Semaphore(1)
        try:
            timing["start"] = time.monotonic()
            return await _run_cluster(
                spec=_make_spec("dir-2", ["f.py"]),
                tier_agents=_make_tier_agents(1),
                sem=sem,
                dispatch_ctx=ctx,
                cluster_index=2,
                cycle_number=1,
                diff_text_fallback="",
            )
        finally:
            ctx.cleanup()

    with patch(
        "dso_ci_review.runner.async_dispatch_specialists", side_effect=_capture_dispatch
    ):
        asyncio.run(_run())

    assert timing["start"] is not None and timing["end"] is not None
    elapsed = timing["end"] - timing["start"]
    expected = 2 * _CYCLE_1_STAGGER_S
    assert expected - 0.05 <= elapsed, (
        f"Stagger missing: expected ≥ {expected:.2f}s, got {elapsed:.3f}s"
    )


def test_cycle_2_skips_stagger():
    """cycle_number != 1 should not stagger, regardless of cluster_index."""
    timing = {"start": None, "end": None}

    async def _capture_dispatch(agents, *, dispatch_context=None):
        timing["end"] = time.monotonic()
        return [{"findings": []} for _ in agents]

    async def _run():
        ctx = DispatchContext.create()
        sem = asyncio.Semaphore(1)
        try:
            timing["start"] = time.monotonic()
            return await _run_cluster(
                spec=_make_spec("dir-4", ["f.py"]),
                tier_agents=_make_tier_agents(1),
                sem=sem,
                dispatch_ctx=ctx,
                cluster_index=4,
                cycle_number=2,
                diff_text_fallback="",
            )
        finally:
            ctx.cleanup()

    with patch(
        "dso_ci_review.runner.async_dispatch_specialists", side_effect=_capture_dispatch
    ):
        asyncio.run(_run())

    elapsed = timing["end"] - timing["start"]
    assert elapsed < _CYCLE_1_STAGGER_S, (
        f"Unexpected stagger on cycle 2: {elapsed:.3f}s ≥ {_CYCLE_1_STAGGER_S}s"
    )


class TestClusterConcurrencyConfig:
    @staticmethod
    def _point_config(monkeypatch, tmp_path, content: str):
        cfg = tmp_path / "dso-config.conf"
        cfg.write_text(content)
        from dso_ci_review import _config as cfg_mod

        monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(cfg))

    def test_default_is_2(self):
        assert _cluster_concurrency() == 2

    def test_config_override(self, monkeypatch, tmp_path):
        self._point_config(
            monkeypatch, tmp_path, "review.region_split.cluster_concurrency=3\n"
        )
        assert _cluster_concurrency() == 3

    def test_invalid_negative_falls_back(self, monkeypatch, tmp_path):
        self._point_config(
            monkeypatch, tmp_path, "review.region_split.cluster_concurrency=-5\n"
        )
        assert _cluster_concurrency() == 2

    def test_value_above_hard_cap_is_clamped(self, monkeypatch, tmp_path):
        self._point_config(
            monkeypatch,
            tmp_path,
            "review.region_split.cluster_concurrency=10\n"
            "review.region_split.max_clusters=8\n",
        )
        assert _cluster_concurrency() == 3

    def test_value_above_max_clusters_is_clamped(self, monkeypatch, tmp_path):
        self._point_config(
            monkeypatch,
            tmp_path,
            "review.region_split.cluster_concurrency=3\n"
            "review.region_split.max_clusters=2\n",
        )
        assert _cluster_concurrency() == 2
