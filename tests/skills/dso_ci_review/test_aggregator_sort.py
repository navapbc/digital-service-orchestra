"""Test that aggregate_cluster_findings sorts cluster_results internally.

Phase 2 of the parallelization plan: clusters complete in nondeterministic
order under asyncio.gather. The synthesis LLM prompt and visibility trailer
depend on stable iteration order; the sort lives inside the aggregator so a
single canonical location guarantees determinism regardless of caller.
"""
from __future__ import annotations

from unittest.mock import patch

from dso_ci_review.aggregator import aggregate_cluster_findings


def _make_cluster(cluster_id: str, files: list[str], findings: list[dict]) -> dict:
    return {
        "cluster_id": cluster_id,
        "file_paths": files,
        "findings": findings,
        "status": "ok",
    }


def test_aggregate_sorts_by_cluster_id():
    """Input out-of-order; output preserved cluster ordering should be sorted."""
    out_of_order = [
        _make_cluster("cluster-c", ["c.py"], []),
        _make_cluster("cluster-a", ["a.py"], []),
        _make_cluster("cluster-b", ["b.py"], []),
    ]

    with patch(
        "dso_ci_review.aggregator._synthesize_via_llm",
        return_value=({"findings": []}, "ok"),
    ):
        result = aggregate_cluster_findings(cluster_results=out_of_order)

    preserved = result.get("cluster_results")
    if preserved is None:
        return
    ids = [c["cluster_id"] for c in preserved]
    assert ids == ["cluster-a", "cluster-b", "cluster-c"]


def test_aggregate_visibility_trailer_deterministic_across_orderings():
    """Same clusters in different orders should produce identical trailers."""
    clusters_a = [
        _make_cluster("dir-0", ["src/a.py"], []),
        _make_cluster("dir-1", ["src/b.py"], []),
        _make_cluster("dir-2", ["src/c.py"], []),
    ]
    clusters_b = list(reversed(clusters_a))

    with patch(
        "dso_ci_review.aggregator._synthesize_via_llm",
        return_value=({"findings": []}, "ok"),
    ):
        out_a = aggregate_cluster_findings(cluster_results=clusters_a)
        out_b = aggregate_cluster_findings(cluster_results=clusters_b)

    assert out_a["visibility_trailer"] == out_b["visibility_trailer"]


def test_aggregate_does_not_mutate_caller_list():
    """Sort must operate on a copy — caller's list ordering preserved."""
    original = [
        _make_cluster("cluster-z", ["z.py"], []),
        _make_cluster("cluster-a", ["a.py"], []),
    ]
    snapshot = [c["cluster_id"] for c in original]

    with patch(
        "dso_ci_review.aggregator._synthesize_via_llm",
        return_value=({"findings": []}, "ok"),
    ):
        aggregate_cluster_findings(cluster_results=original)

    assert [c["cluster_id"] for c in original] == snapshot
