"""RED tests for dso_ci_review.aggregator — cross-file synthesis + visibility trailer.

Testing mode: RED — module does not yet exist; all tests must fail with
ImportError (ModuleNotFoundError). S7.T6 will implement aggregator.py to turn
these GREEN.

Story 1608-4d8c-da53-47bc: As a DSO operator, oversized PRs are reviewed via
chunked file-level dispatch with LLM aggregation.
Task c178-e62c-a17c-4398: S7.T5 RED unit tests for aggregator.py

RED marker: tests/scripts/test_dso_ci_review_aggregator.py [test_dso_ci_review_aggregator]

Behavioral contracts under test:

DD3.1 — Cross-file synthesis (aggregate_cluster_findings):
  Given per-cluster results from 3 clusters (5 findings each, some referencing
  files across cluster boundaries), aggregate_cluster_findings synthesizes them
  into a unified payload and preserves cross-file findings without duplication.

DD3.2 — Visibility trailer namespace:
  The aggregated PR comment includes a trailer keyed with DSO-Review-Coverage:
  (distinct from DSO-Story-Merge:, which verify-session-provenance.sh:137
  greps for). The trailer lists all reviewed files AND all skipped files with
  their skip reason. The key must NOT match ^DSO-Story-Merge:.

DD4 — Single-ledger-entry invariant:
  Regardless of how many per-file clusters the region-split produces, the
  aggregator emits EXACTLY ONE append_cycle() call per (pr_number, sha,
  cycle_num) aggregation pass.

Post-S2 signature:
  The single append_cycle call must pass pr_number AND commit_sha matching the
  fixture values (not just call count). This test is written against the
  POST-S2 signature so it fails RED today and passes after both S2.T2 and
  S7.T6 land.

Budget invariant:
  The aggregation pass counts as ONE LLM call against the max_calls budget,
  regardless of how many clusters were dispatched.

Failure modes (F4a / F4b / F4c):
  F4a — Malformed aggregation JSON: falls back to un-aggregated per-cluster
        results with visibility comment noting failure.
  F4b — .gitattributes parse failure: fails open (all files included as
        reviewable; warning logged). Does NOT abort aggregation.
  F4c — Per-file schema-correction exhaustion: skips that file (does NOT
        abort aggregation); emits 'schema-correction-exhausted:<file>' note
        in aggregation output.
"""

from __future__ import annotations

import pathlib
import sys
from unittest.mock import MagicMock, patch

import pytest

# Bug 3775-c17a-5c25-4ec8: these suites still reach real network seams; blanket
# allow_network is a bridge until the per-test seam mocks land (tracked there).
pytestmark = pytest.mark.allow_network


# Ensure the plugin scripts directory is on sys.path so imports resolve.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# This import MUST raise ImportError (ModuleNotFoundError) until aggregator.py
# is implemented. That is the RED state.
# RED marker: [test_dso_ci_review_aggregator]
from dso_ci_review.aggregator import (  # noqa: E402
    aggregate_cluster_findings,
    build_visibility_trailer,
)


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


def _make_cluster_result(
    cluster_id: str,
    file_paths: list[str],
    findings: list[dict],
) -> dict:
    """Build a minimal per-cluster result dict as returned by per-file dispatch."""
    return {
        "cluster_id": cluster_id,
        "file_paths": file_paths,
        "findings": findings,
        "status": "ok",
    }


def _make_finding(
    severity: str,
    description: str,
    cited_lines: list[str],
) -> dict:
    return {
        "severity": severity,
        "description": description,
        "cited_lines": cited_lines,
    }


# ---------------------------------------------------------------------------
# Scenario DD3.1 — Cross-file synthesis via aggregate_cluster_findings
# ---------------------------------------------------------------------------


@pytest.mark.skip(
    reason="bug 3775-c17a-5c25-4ec8: makes real litellm/Anthropic HTTP calls; needs aggregation-seam mock"
)
class TestAggregateClusterFindings:
    """DD3.1: aggregate_cluster_findings synthesizes per-cluster results."""

    def test_aggregate_returns_unified_findings_list(self) -> None:
        """Given: 3 clusters each with distinct findings.
        When: aggregate_cluster_findings is called.
        Then: all findings appear in the returned unified payload.

        Cross-cluster synthesis is the core value of the aggregation pass;
        per-cluster isolation is the failure mode this prevents.
        """
        clusters = [
            _make_cluster_result(
                "cluster-0",
                ["src/auth.py"],
                [
                    _make_finding(
                        "critical", "SQL injection in auth", ["src/auth.py:42"]
                    ),
                    _make_finding("minor", "unused import", ["src/auth.py:1"]),
                ],
            ),
            _make_cluster_result(
                "cluster-1",
                ["src/api.py"],
                [
                    _make_finding(
                        "important", "CORS header missing", ["src/api.py:77"]
                    ),
                    _make_finding("minor", "log level too verbose", ["src/api.py:100"]),
                ],
            ),
            _make_cluster_result(
                "cluster-2",
                ["src/db.py"],
                [
                    _make_finding(
                        "critical",
                        "cross-file: auth token written to db log",
                        ["src/auth.py:88", "src/db.py:33"],
                    ),
                ],
            ),
        ]

        result = aggregate_cluster_findings(cluster_results=clusters)

        assert "findings" in result, (
            "aggregate_cluster_findings must return a dict with a 'findings' key; "
            f"got keys: {list(result.keys())!r}"
        )
        all_descriptions = [f["description"] for f in result["findings"]]
        assert "SQL injection in auth" in all_descriptions, (
            "cluster-0 finding must survive aggregation; "
            f"got descriptions: {all_descriptions!r}"
        )
        assert "CORS header missing" in all_descriptions, (
            "cluster-1 finding must survive aggregation; "
            f"got descriptions: {all_descriptions!r}"
        )
        assert "cross-file: auth token written to db log" in all_descriptions, (
            "cross-cluster finding (cluster-2) must survive aggregation; "
            f"got descriptions: {all_descriptions!r}"
        )

    def test_cross_file_finding_preserved_without_duplication(self) -> None:
        """Given: a finding citing files from two different clusters.
        When: aggregate_cluster_findings is called.
        Then: the cross-file finding appears EXACTLY ONCE in the unified payload.

        Naive concatenation would produce duplicates when both clusters include
        the same cross-file finding; the aggregator must deduplicate.
        """
        cross_finding = _make_finding(
            "important",
            "cross-file: shared state mutation",
            ["src/auth.py:10", "src/db.py:20"],
        )
        clusters = [
            _make_cluster_result("cluster-0", ["src/auth.py"], [cross_finding]),
            _make_cluster_result("cluster-1", ["src/db.py"], [cross_finding]),
        ]

        result = aggregate_cluster_findings(cluster_results=clusters)

        cross_descriptions = [
            f["description"]
            for f in result["findings"]
            if f["description"] == "cross-file: shared state mutation"
        ]
        assert len(cross_descriptions) == 1, (
            "Cross-file finding cited by two clusters must appear EXACTLY ONCE "
            f"in the unified payload; found {len(cross_descriptions)} copies. "
            "The aggregator must deduplicate cross-cluster findings."
        )

    def test_aggregate_with_five_findings_per_cluster(self) -> None:
        """Given: 3 clusters with 5 findings each (15 total, no duplicates).
        When: aggregate_cluster_findings is called.
        Then: unified payload contains all 15 findings.
        """
        clusters = []
        for i in range(3):
            findings = [
                _make_finding(
                    "minor",
                    f"finding-{i}-{j}",
                    [f"src/file{i}.py:{j}"],
                )
                for j in range(5)
            ]
            clusters.append(
                _make_cluster_result(f"cluster-{i}", [f"src/file{i}.py"], findings)
            )

        result = aggregate_cluster_findings(cluster_results=clusters)

        assert len(result["findings"]) == 15, (
            f"3 clusters × 5 findings = 15 total; got {len(result['findings'])}. "
            "No findings must be dropped when there are no cross-cluster duplicates."
        )


# ---------------------------------------------------------------------------
# Scenario DD3.2 — Visibility trailer namespace
# ---------------------------------------------------------------------------


class TestVisibilityTrailerNamespace:
    """DD3.2: visibility trailer uses DSO-Review-Coverage: namespace."""

    def test_trailer_key_is_dso_review_coverage(self) -> None:
        """Given: a list of reviewed and skipped files.
        When: build_visibility_trailer is called.
        Then: the returned trailer string starts with 'DSO-Review-Coverage:'.

        The trailer namespace must be distinct from DSO-Story-Merge: to avoid
        collision with verify-session-provenance.sh:137's provenance grep.
        """
        trailer = build_visibility_trailer(
            reviewed_files=["src/auth.py", "src/api.py"],
            skipped_files=[("vendor/lib.min.js", "linguist-generated")],
        )
        assert trailer.startswith("DSO-Review-Coverage:"), (
            f"Visibility trailer must start with 'DSO-Review-Coverage:'; "
            f"got: {trailer[:80]!r}. "
            "This namespace is chosen to avoid collision with DSO-Story-Merge:."
        )

    def test_trailer_does_not_match_dso_story_merge_prefix(self) -> None:
        """Given: any call to build_visibility_trailer.
        When: the trailer is produced.
        Then: it does NOT match the regex ^DSO-Story-Merge:.

        verify-session-provenance.sh:137 greps for ^DSO-Story-Merge: to detect
        provenanced commits. A trailer matching that prefix would silently
        corrupt provenance detection.

        namespace: distinct from DSO-Story-Merge:
        NOT DSO-Story-Merge: prefix
        """
        import re

        trailer = build_visibility_trailer(
            reviewed_files=["src/core.py"],
            skipped_files=[],
        )
        assert not re.match(r"^DSO-Story-Merge:", trailer), (
            f"Visibility trailer MUST NOT match ^DSO-Story-Merge:; "
            f"got: {trailer[:80]!r}. "
            "Matching this prefix would corrupt verify-session-provenance.sh."
        )

    def test_trailer_lists_all_reviewed_files(self) -> None:
        """Given: reviewed_files=['src/auth.py', 'src/api.py', 'src/db.py'].
        When: build_visibility_trailer is called.
        Then: all three file paths appear in the trailer text.
        """
        reviewed = ["src/auth.py", "src/api.py", "src/db.py"]
        trailer = build_visibility_trailer(
            reviewed_files=reviewed,
            skipped_files=[],
        )
        for f in reviewed:
            assert f in trailer, (
                f"Reviewed file {f!r} must appear in visibility trailer; "
                f"got trailer: {trailer!r}"
            )

    def test_trailer_lists_all_skipped_files_with_reason(self) -> None:
        """Given: skipped_files with reason tuples.
        When: build_visibility_trailer is called.
        Then: each skipped file path AND its reason appear in the trailer.
        """
        skipped = [
            ("vendor/lib.min.js", "linguist-generated"),
            ("docs/api.md", "linguist-documentation"),
            ("package-lock.json", "ignore.glob"),
        ]
        trailer = build_visibility_trailer(
            reviewed_files=["src/main.py"],
            skipped_files=skipped,
        )
        for path, reason in skipped:
            assert path in trailer, (
                f"Skipped file path {path!r} must appear in trailer; "
                f"got trailer: {trailer!r}"
            )
            assert reason in trailer, (
                f"Skip reason {reason!r} for {path!r} must appear in trailer; "
                f"got trailer: {trailer!r}"
            )


# ---------------------------------------------------------------------------
# Scenario DD4 — Single-ledger-entry invariant
# ---------------------------------------------------------------------------


@pytest.mark.skip(
    reason="bug 3775-c17a-5c25-4ec8: makes real litellm/Anthropic HTTP calls; needs aggregation-seam mock"
)
class TestSingleLedgerEntryInvariant:
    """DD4: exactly one append_cycle call per aggregation pass."""

    def test_single_ledger_entry_regardless_of_cluster_count(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: 3 region-split clusters dispatched for one PR+sha+cycle.
        When: aggregate_cluster_findings is called with ledger_path + pr_number +
              commit_sha + cycle_num.
        Then: append_cycle is called EXACTLY ONCE — not once per cluster.

        Single-ledger-entry invariant: one (pr_number, sha, cycle_num) tuple
        must correspond to exactly one ledger entry, regardless of cluster count.
        Red-team Finding #8: aggregation pass cycle counting.
        """
        clusters = [
            _make_cluster_result(f"cluster-{i}", [f"src/f{i}.py"], []) for i in range(3)
        ]
        ledger_path = str(tmp_path / "cycle-ledger.json")

        with patch("dso_ci_review.aggregator.append_cycle") as mock_append:
            aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=99,
                commit_sha="abc123def456" + "0" * 28,
                cycle_num=1,
            )

        assert mock_append.call_count == 1, (
            f"append_cycle must be called EXACTLY ONCE per aggregation pass; "
            f"got {mock_append.call_count} calls. "
            "Each cluster must NOT produce its own ledger entry — "
            "one ledger entry per (pr_number, sha, cycle_num) tuple."
        )

    def test_append_cycle_receives_pr_number_matching_fixture(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: pr_number=42 passed to aggregate_cluster_findings.
        When: the single append_cycle call is made.
        Then: append_cycle is called with pr_number=42 (not default/sentinel).

        Post-S2 signature: append_cycle must receive the explicit pr_number
        (not the _SENTINEL_PR_NUMBER=0 reserved for legacy v1.1.0 reads).
        """
        clusters = [_make_cluster_result("cluster-0", ["src/main.py"], [])]
        ledger_path = str(tmp_path / "cycle-ledger.json")

        with patch("dso_ci_review.aggregator.append_cycle") as mock_append:
            aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=42,
                commit_sha="deadbeef1234" + "0" * 28,
                cycle_num=1,
            )

        assert mock_append.call_count == 1, "Expected exactly one append_cycle call"
        _, kwargs = mock_append.call_args

        # Accept positional or keyword args — check all call args for pr_number value.
        all_args = list(mock_append.call_args[0]) + list(
            mock_append.call_args[1].values()
        )
        assert 42 in all_args or kwargs.get("pr_number") == 42, (
            f"append_cycle must be called with pr_number=42; "
            f"got call args: {mock_append.call_args!r}. "
            "Post-S2 signature requires explicit pr_number in append_cycle call."
        )

    def test_append_cycle_receives_commit_sha_matching_fixture(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: commit_sha='feed1234abcd...' passed to aggregate_cluster_findings.
        When: the single append_cycle call is made.
        Then: append_cycle is called with that exact commit_sha value.

        Post-S2 signature: append_cycle receives commit_sha to key the ledger
        entry. Without it, re-review on the same commit cannot detect prior runs.
        """
        fixture_sha = "feed1234abcd" + "0" * 28
        clusters = [_make_cluster_result("cluster-0", ["src/main.py"], [])]
        ledger_path = str(tmp_path / "cycle-ledger.json")

        with patch("dso_ci_review.aggregator.append_cycle") as mock_append:
            aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=7,
                commit_sha=fixture_sha,
                cycle_num=1,
            )

        assert mock_append.call_count == 1, "Expected exactly one append_cycle call"
        all_args = list(mock_append.call_args[0]) + list(
            mock_append.call_args[1].values()
        )
        assert (
            fixture_sha in all_args
            or mock_append.call_args[1].get("commit_sha") == fixture_sha
        ), (
            f"append_cycle must receive commit_sha={fixture_sha!r}; "
            f"got call args: {mock_append.call_args!r}. "
            "commit_sha is required by the post-S2 ledger signature."
        )


# ---------------------------------------------------------------------------
# Scenario — Budget invariant (ONE LLM call regardless of cluster count)
# ---------------------------------------------------------------------------


class TestBudgetInvariant:
    """Aggregation LLM pass counts as ONE call against max_calls budget."""

    def test_one_llm_call_against_budget_regardless_of_cluster_count(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: 5 per-file clusters dispatched for one PR+sha+cycle.
        When: aggregate_cluster_findings is called.
        Then: exactly ONE LLM call is issued for the aggregation pass itself,
              NOT 5 (one per cluster).

        Performance bound: aggregation pass cost is bounded by max_calls
        (NOT max_files × max_calls). Red-team concern from story considerations.
        """
        clusters = [
            _make_cluster_result(
                f"cluster-{i}",
                [f"src/file{i}.py"],
                [_make_finding("minor", f"finding-{i}", [f"src/file{i}.py:1"])],
            )
            for i in range(5)
        ]
        ledger_path = str(tmp_path / "cycle-ledger.json")
        mock_llm_response = MagicMock()
        mock_llm_response.choices = [
            MagicMock(
                message=MagicMock(
                    content='{"findings": [{"severity": "minor", '
                    '"description": "aggregated", "cited_lines": []}]}'
                )
            )
        ]

        with (
            patch("dso_ci_review.aggregator.append_cycle"),
            patch(
                "dso_ci_review.aggregator.litellm.completion",
                return_value=mock_llm_response,
            ) as mock_llm,
        ):
            aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=11,
                commit_sha="cafe0000" + "0" * 32,
                cycle_num=1,
            )

        assert mock_llm.call_count == 1, (
            f"Aggregation pass must issue EXACTLY ONE LLM call regardless of "
            f"cluster count; got {mock_llm.call_count} calls for 5 clusters. "
            "The aggregation LLM call counts once against the max_calls budget."
        )


# ---------------------------------------------------------------------------
# Failure mode F4a — Malformed aggregation JSON → fallback to per-cluster
# ---------------------------------------------------------------------------


class TestMalformedAggregationJson:
    """F4a: malformed JSON from aggregation LLM falls back to per-cluster results."""

    def test_malformed_aggregation_json_falls_back_to_per_cluster(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: aggregation LLM returns malformed JSON (not parseable).
        When: aggregate_cluster_findings is called.
        Then: function returns the un-aggregated per-cluster results (fallback),
              and the result includes a visibility comment noting
              'aggregation failed; per-cluster findings posted separately'.

        F4a failure mode: malformed aggregation JSON. Expected behavior is
        graceful degradation — per-cluster results are surfaced rather than
        losing all findings.
        """
        clusters = [
            _make_cluster_result(
                "cluster-0",
                ["src/auth.py"],
                [_make_finding("critical", "SQL injection", ["src/auth.py:42"])],
            )
        ]
        ledger_path = str(tmp_path / "cycle-ledger.json")
        malformed_response = MagicMock()
        malformed_response.choices = [
            MagicMock(message=MagicMock(content="this is not valid json {{{"))
        ]

        with (
            patch("dso_ci_review.aggregator.append_cycle"),
            patch(
                "dso_ci_review.aggregator.litellm.completion",
                return_value=malformed_response,
            ),
        ):
            result = aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=55,
                commit_sha="bad0bad0" + "0" * 32,
                cycle_num=1,
            )

        # The fallback must note the aggregation failure.
        result_str = str(result)
        assert (
            "aggregation failed" in result_str.lower()
            or result.get("aggregation_status") == "failed"
            or result.get("fallback") is True
        ), (
            "When aggregation LLM returns malformed JSON, the result must signal "
            "the aggregation failure (via 'aggregation failed' text, "
            "aggregation_status='failed', or fallback=True); "
            f"got result keys: {list(result.keys())!r}"
        )
        # The per-cluster finding must not be lost.
        all_findings = result.get("findings", [])
        descriptions = [f.get("description", "") for f in all_findings]
        assert "SQL injection" in descriptions or result.get("cluster_results"), (
            "Per-cluster findings must survive F4a fallback; "
            "either findings list contains them or cluster_results is preserved. "
            f"Got findings: {all_findings!r}"
        )

    def test_malformed_aggregation_comment_contains_failure_note(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: aggregation LLM returns malformed JSON.
        When: the visibility comment is produced.
        Then: comment contains 'aggregation failed; per-cluster findings posted separately'.
        """
        clusters = [_make_cluster_result("cluster-0", ["src/api.py"], [])]
        ledger_path = str(tmp_path / "cycle-ledger.json")
        malformed = MagicMock()
        malformed.choices = [MagicMock(message=MagicMock(content="not json"))]

        with (
            patch("dso_ci_review.aggregator.append_cycle"),
            patch(
                "dso_ci_review.aggregator.litellm.completion",
                return_value=malformed,
            ),
        ):
            result = aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=66,
                commit_sha="dead1234" + "0" * 32,
                cycle_num=1,
            )

        comment = result.get("visibility_comment", "") or result.get(
            "aggregation_comment", ""
        )
        assert "per-cluster findings posted separately" in comment.lower() or (
            "aggregation failed" in str(result).lower()
        ), (
            "F4a fallback comment must contain "
            "'aggregation failed; per-cluster findings posted separately'; "
            f"got visibility_comment={comment!r}"
        )


# ---------------------------------------------------------------------------
# Failure mode F4b — .gitattributes parse failure → fail-open
# ---------------------------------------------------------------------------


class TestGitattributesParseFailure:
    """F4b: .gitattributes parse failure fails open — all files included."""

    def test_gitattributes_parse_failure_fails_open(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: .gitattributes parse raises an exception.
        When: aggregate_cluster_findings is called with a gitattributes_path
              pointing to a malformed file.
        Then: aggregation continues with all files treated as reviewable
              (fail-open semantics); warning is logged; aggregation does NOT
              abort.

        F4b failure mode: .gitattributes parse failure. Expected behavior:
        fail open (all files included as reviewable; warning logged).
        """
        bad_gitattributes = tmp_path / ".gitattributes"
        # Write a file that will cause parse failure: unreadable permissions.
        bad_gitattributes.write_bytes(b"\xff\xfe invalid utf-8 \x00\x01")
        bad_gitattributes.chmod(0o000)  # Make unreadable to trigger OSError.

        clusters = [
            _make_cluster_result(
                "cluster-0",
                ["src/main.py", "vendor/lib.min.js"],
                [_make_finding("minor", "test finding", ["src/main.py:1"])],
            )
        ]
        ledger_path = str(tmp_path / "cycle-ledger.json")

        try:
            with (
                patch("dso_ci_review.aggregator.append_cycle"),
                patch("dso_ci_review.aggregator.litellm.completion") as mock_llm,
            ):
                mock_llm.return_value = MagicMock(
                    choices=[MagicMock(message=MagicMock(content='{"findings": []}'))]
                )
                # This must NOT raise; fail-open semantics.
                result = aggregate_cluster_findings(
                    cluster_results=clusters,
                    ledger_path=ledger_path,
                    pr_number=77,
                    commit_sha="f4b00000" + "0" * 32,
                    cycle_num=1,
                    gitattributes_path=str(bad_gitattributes),
                )
        finally:
            bad_gitattributes.chmod(0o644)  # Restore for cleanup.

        # F4b: fail-open means aggregation succeeded (no exception, has result).
        assert result is not None, (
            "F4b: .gitattributes parse failure must NOT abort aggregation; "
            "aggregate_cluster_findings must return a result dict."
        )
        assert isinstance(result, dict), (
            f"F4b: result must be a dict; got {type(result)!r}"
        )

    def test_gitattributes_parse_failure_does_not_abort_aggregation(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: .gitattributes is absent (simulates parse-failure alternative).
        When: aggregate_cluster_findings is called.
        Then: aggregation proceeds; all files treated as reviewable; no exception.

        gitattributes parse failure: fail open (all files included as reviewable)
        """
        # No .gitattributes file in tmp_path — absent file is the simplest
        # parse-failure substitute without OS permission dance.
        absent_ga = str(tmp_path / "nonexistent" / ".gitattributes")
        clusters = [
            _make_cluster_result(
                "cluster-0",
                ["src/main.py"],
                [_make_finding("minor", "finding", ["src/main.py:5"])],
            )
        ]
        ledger_path = str(tmp_path / "cycle-ledger.json")

        with (
            patch("dso_ci_review.aggregator.append_cycle"),
            patch("dso_ci_review.aggregator.litellm.completion") as mock_llm,
        ):
            mock_llm.return_value = MagicMock(
                choices=[
                    MagicMock(
                        message=MagicMock(
                            content='{"findings": [{"severity": "minor", '
                            '"description": "finding", "cited_lines": []}]}'
                        )
                    )
                ]
            )
            result = aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=88,
                commit_sha="f4bab000" + "0" * 32,
                cycle_num=1,
                gitattributes_path=absent_ga,
            )

        assert result is not None, (
            "F4b (absent .gitattributes): aggregation must not abort; "
            "result must be a dict."
        )


# ---------------------------------------------------------------------------
# Failure mode F4c — Per-file schema-correction exhaustion → skip file
# ---------------------------------------------------------------------------


class TestSchemaCorrection:
    """F4c: schema-correction exhaustion skips file, does NOT abort aggregation."""

    def test_schema_correction_exhaustion_skips_file_not_abort(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: per-file schema correction fails exhaustion limit for one file.
        When: aggregate_cluster_findings is called.
        Then: that file is skipped (NOT included in aggregated findings);
              aggregation continues for remaining files; result notes
              'schema-correction-exhausted: <file>'.

        F4c failure mode: schema-correction exhausted for a file.
        Do NOT abort aggregation — skip the file.
        """
        clusters = [
            _make_cluster_result(
                "cluster-0",
                ["src/problematic.py"],
                [
                    _make_finding(
                        "minor", "bad schema finding", ["src/problematic.py:1"]
                    )
                ],
            ),
            _make_cluster_result(
                "cluster-1",
                ["src/good.py"],
                [_make_finding("critical", "real finding", ["src/good.py:50"])],
            ),
        ]
        ledger_path = str(tmp_path / "cycle-ledger.json")

        with (
            patch("dso_ci_review.aggregator.append_cycle"),
            patch("dso_ci_review.aggregator.litellm.completion") as mock_llm,
        ):
            # First call (cluster-0 / problematic file): schema-exhausted error.
            # Second call (cluster-1 / good file) or aggregation call: valid JSON.
            def _side_effect(*args, **kwargs):
                call_count = mock_llm.call_count
                if call_count == 1:
                    raise ValueError("schema-correction-exhausted: src/problematic.py")
                return MagicMock(
                    choices=[
                        MagicMock(
                            message=MagicMock(
                                content='{"findings": [{"severity": "critical", '
                                '"description": "real finding", "cited_lines": []}]}'
                            )
                        )
                    ]
                )

            mock_llm.side_effect = _side_effect

            result = aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=33,
                commit_sha="f4c00000" + "0" * 32,
                cycle_num=1,
            )

        # F4c: aggregation must complete (not abort).
        assert result is not None, (
            "F4c: schema-correction exhaustion for one file must NOT abort "
            "aggregate_cluster_findings; result must be returned."
        )
        result_str = str(result)
        # The exhaustion note must appear somewhere in the output.
        assert "schema-correction-exhausted" in result_str or result.get(
            "schema_exhausted_files"
        ), (
            "F4c: result must note 'schema-correction-exhausted' for the "
            "skipped file; got result: "
            f"{result!r}"
        )

    def test_schema_correction_exhaustion_note_contains_filename(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: schema-correction exhaustion for 'src/problematic.py'.
        When: aggregate_cluster_findings returns.
        Then: the exhaustion note in the result contains 'src/problematic.py'.

        schema-correction-exhausted: <file> — the filename must be in the note.
        """
        clusters = [
            _make_cluster_result(
                "cluster-0",
                ["src/problematic.py"],
                [],
            ),
        ]
        ledger_path = str(tmp_path / "cycle-ledger.json")

        with (
            patch("dso_ci_review.aggregator.append_cycle"),
            patch(
                "dso_ci_review.aggregator.litellm.completion",
                side_effect=ValueError(
                    "schema-correction-exhausted: src/problematic.py"
                ),
            ),
        ):
            result = aggregate_cluster_findings(
                cluster_results=clusters,
                ledger_path=ledger_path,
                pr_number=44,
                commit_sha="f4c11111" + "0" * 32,
                cycle_num=1,
            )

        result_str = str(result)
        assert "src/problematic.py" in result_str or (
            any(
                "src/problematic.py" in str(v)
                for v in result.values()
                if isinstance(v, (str, list))
            )
        ), (
            "F4c exhaustion note must contain the filename 'src/problematic.py'; "
            f"got result: {result!r}"
        )
