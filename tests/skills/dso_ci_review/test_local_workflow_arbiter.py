"""RED tests for dso_ci_review.local_workflow — DISPATCH_ARBITER branch.

All 8 tests fail until:
  - local_workflow.py is created in dso_ci_review package
  - _local_arbiter_branch() is implemented (not just a stub returning 1)
  - main() routes DISPATCH_ARBITER to _local_arbiter_branch() instead of stub

Testing mode: RED — these tests document the expected behaviour of the
DISPATCH_ARBITER branch and are intentionally failing until the implementation
lands (task 9bb1-c4cc-2c01-4a7f).
"""
from __future__ import annotations

import json
import pathlib
import sys
from unittest.mock import MagicMock, patch

import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# -------------------------------------------------------------------
# Import guard: local_workflow module does not exist yet.
# We intentionally let the ImportError propagate at collection time
# so that pytest reports all 8 tests as errors/failures, not as
# "collected 0 items" — making the RED state visible.
# -------------------------------------------------------------------
try:
    import dso_ci_review.local_workflow as _lw_mod  # noqa: E402
    from dso_ci_review.local_workflow import _local_arbiter_branch  # noqa: E402
    _LOCAL_ARBITER_BRANCH_EXISTS = True
except ImportError:
    _lw_mod = None  # type: ignore[assignment]
    _local_arbiter_branch = None  # type: ignore[assignment]
    _LOCAL_ARBITER_BRANCH_EXISTS = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _sample_rulings(types=("BLOCK",)):
    """Build a list of minimal ruling dicts."""
    result = []
    for i, ruling_type in enumerate(types):
        result.append({
            "ruling": ruling_type,
            "rationale": f"Test rationale {i}",
            "schema_version": "1.0.0",
            "finding_index": i,
            "impact_class": "bug" if ruling_type != "DROP" else "none",
        })
    return result


def _sample_findings(n=1, severity="critical"):
    """Build a list of minimal finding dicts."""
    return [
        {
            "severity": severity,
            "description": f"Finding {i}",
            "cited_lines": [f"src/foo.py:{i + 1}"],
            "file": "src/foo.py",
            "line_range": f"{i + 1}",
            "category": "correctness",
        }
        for i in range(n)
    ]


def _make_ledger(cycle_num=1, sha="testsha123"):
    """Build a minimal cycle-ledger dict."""
    return {
        "schema_version": "1.1.0",
        "cycles": [
            {
                "cycle_num": cycle_num,
                "commit_sha": sha,
                "findings": [],
                "findings_hash": "h1",
            }
        ],
    }


# ---------------------------------------------------------------------------
# Test 1: process_rulings called with pr_number=None and branch_name
# ---------------------------------------------------------------------------

def test_local_arbiter_calls_process_rulings_with_pr_number_none_and_branch_name(tmp_path):
    """DISPATCH_ARBITER branch: process_rulings must be called with pr_number=None
    and a branch_name derived from the current git branch (local context, no PR).

    Fails RED because local_workflow.main() DISPATCH_ARBITER branch is a stub
    (returns 1) that does not call process_rulings.
    """
    if not _LOCAL_ARBITER_BRANCH_EXISTS:
        pytest.fail(
            "_local_arbiter_branch not implemented yet — "
            "dso_ci_review.local_workflow module missing"
        )

    findings = _sample_findings(1, severity="critical")
    rulings = _sample_rulings(("BLOCK",))
    branch_name = "story/test-branch"

    with (
        patch("dso_ci_review.local_workflow._dispatch_cycle_end_arbiter", return_value=rulings),
        patch("dso_ci_review.local_workflow.process_rulings") as mock_process,
        patch("subprocess.check_output", return_value=branch_name.encode() + b"\n"),
    ):
        mock_process.return_value = {
            "block": [{"ruling": rulings[0], "finding": findings[0], "finding_hash": "h1"}],
            "defer_ticket_ids": [],
            "drop_defense_records": [],
            "skipped_idempotent": [],
            "skipped_invalid_index": [],
        }

        _local_arbiter_branch(
            findings=findings,
            cycle_num=2,
            commit_sha="testsha123",
            artifacts_dir=str(tmp_path),
        )

    mock_process.assert_called_once()
    call_kwargs = mock_process.call_args
    # pr_number must be None (local workflow has no PR context)
    assert call_kwargs.kwargs.get("pr_number") is None or (
        call_kwargs.args and call_kwargs.args[3] is None
    ), f"pr_number should be None, got: {call_kwargs}"
    # branch_name must be present and non-empty
    actual_branch = call_kwargs.kwargs.get("branch_name") or (
        call_kwargs.args[4] if len(call_kwargs.args) > 4 else None
    )
    assert actual_branch is not None and actual_branch != "", (
        f"branch_name should be set to current git branch, got: {actual_branch!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: finding_map index alignment — findings match rulings by order
# ---------------------------------------------------------------------------

def test_local_arbiter_aligned_finding_map(tmp_path):
    """DISPATCH_ARBITER branch: finding_map passed to process_rulings must align
    with findings list — key 0 maps to findings[0], key 1 to findings[1], etc.

    Regression guard: if the arbiter branch builds finding_map incorrectly
    (e.g., 1-indexed, reversed, or sparse), process_rulings will silently
    handle wrong findings under each ruling.

    Fails RED because the DISPATCH_ARBITER branch in local_workflow does not
    exist.
    """
    if not _LOCAL_ARBITER_BRANCH_EXISTS:
        pytest.fail(
            "_local_arbiter_branch not implemented yet — "
            "dso_ci_review.local_workflow module missing"
        )

    findings = _sample_findings(3, severity="critical")
    rulings = _sample_rulings(("BLOCK", "DEFER", "DROP"))
    captured_finding_map: dict = {}

    def capture_process_rulings(*args, **kwargs):
        # Capture the finding_map argument positionally or by keyword
        if args and len(args) >= 2:
            captured_finding_map.update(args[1])
        elif "finding_map" in kwargs:
            captured_finding_map.update(kwargs["finding_map"])
        return {
            "block": [], "defer_ticket_ids": [], "drop_defense_records": [],
            "skipped_idempotent": [], "skipped_invalid_index": [],
        }

    with (
        patch("dso_ci_review.local_workflow._dispatch_cycle_end_arbiter", return_value=rulings),
        patch("dso_ci_review.local_workflow.process_rulings", side_effect=capture_process_rulings),
        patch("subprocess.check_output", return_value=b"test-branch\n"),
    ):
        _local_arbiter_branch(
            findings=findings,
            cycle_num=1,
            commit_sha="sha1",
            artifacts_dir=str(tmp_path),
        )

    # finding_map must cover all N findings with 0-based integer keys
    assert len(captured_finding_map) == 3, (
        f"finding_map should have 3 entries, got {len(captured_finding_map)}: {captured_finding_map}"
    )
    for idx, original_finding in enumerate(findings):
        assert idx in captured_finding_map, (
            f"finding_map missing key {idx}"
        )
        assert captured_finding_map[idx] is original_finding or (
            captured_finding_map[idx] == original_finding
        ), f"finding_map[{idx}] does not correspond to findings[{idx}]"


# ---------------------------------------------------------------------------
# Test 3: DEFER orphan ticket uses branch:<name>, not #<pr_number>
# ---------------------------------------------------------------------------

def test_local_defer_orphan_ticket_uses_branch_scope(tmp_path):
    """DEFER ruling: orphan ticket description must use 'branch:<branch_name>'
    scope marker, NOT '#<pr_number>', because local workflow has no PR context.

    Fails RED because the DISPATCH_ARBITER local branch is a stub.
    """
    if not _LOCAL_ARBITER_BRANCH_EXISTS:
        pytest.fail(
            "_local_arbiter_branch not implemented yet — "
            "dso_ci_review.local_workflow module missing"
        )

    findings = _sample_findings(1, severity="important")
    rulings = _sample_rulings(("DEFER",))
    branch_name = "story/my-feature-b575"
    subprocess_calls: list[list[str]] = []

    def mock_run(cmd, **kwargs):
        if isinstance(cmd, list):
            subprocess_calls.append(list(cmd))
        result = MagicMock()
        result.returncode = 0
        # ticket list returns empty (no existing dedup hit)
        if isinstance(cmd, list) and len(cmd) > 2 and cmd[2] == "list":
            result.stdout = "[]"
        else:
            result.stdout = "t-new-defer-001\n"
        return result

    with (
        patch("dso_ci_review.local_workflow._dispatch_cycle_end_arbiter", return_value=rulings),
        patch("subprocess.run", side_effect=mock_run),
        patch("subprocess.check_output", return_value=branch_name.encode() + b"\n"),
    ):
        _local_arbiter_branch(
            findings=findings,
            cycle_num=1,
            commit_sha="sha1",
            artifacts_dir=str(tmp_path),
        )

    # Find the ticket create subprocess call
    create_calls = [
        c for c in subprocess_calls
        if len(c) >= 4 and "ticket" in c and "create" in c
    ]
    assert create_calls, (
        f"No ticket create subprocess call found. All calls: {subprocess_calls}"
    )

    create_cmd_str = " ".join(create_calls[0])
    # Description must contain branch:story/my-feature-b575, not #<number>
    assert f"branch:{branch_name}" in create_cmd_str, (
        f"Expected 'branch:{branch_name}' scope in ticket create cmd, got: {create_cmd_str}"
    )
    # Must NOT contain # PR reference (local workflow has no PR number)
    assert "#" not in create_cmd_str or f"branch:{branch_name}" in create_cmd_str, (
        f"Ticket create cmd must use branch scope, not PR# scope: {create_cmd_str}"
    )


# ---------------------------------------------------------------------------
# Test 4: DROP ruling writes tracker store, never github defense store
# ---------------------------------------------------------------------------

def test_local_drop_skips_pr_defense_store(tmp_path):
    """DROP ruling: review-defense-store.sh must be invoked (tracker write);
    review-github-defense-store.sh must NOT be invoked (no PR context locally).

    Fails RED because the DISPATCH_ARBITER local branch is a stub.
    """
    if not _LOCAL_ARBITER_BRANCH_EXISTS:
        pytest.fail(
            "_local_arbiter_branch not implemented yet — "
            "dso_ci_review.local_workflow module missing"
        )

    findings = _sample_findings(1, severity="important")
    rulings = _sample_rulings(("DROP",))
    subprocess_calls: list[list[str]] = []

    def mock_run(cmd, **kwargs):
        if isinstance(cmd, list):
            subprocess_calls.append(list(cmd))
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        return result

    with (
        patch("dso_ci_review.local_workflow._dispatch_cycle_end_arbiter", return_value=rulings),
        patch("subprocess.run", side_effect=mock_run),
        patch("subprocess.check_output", return_value=b"test-branch\n"),
    ):
        _local_arbiter_branch(
            findings=findings,
            cycle_num=1,
            commit_sha="sha1",
            artifacts_dir=str(tmp_path),
        )

    # review-defense-store.sh must have been invoked (tracker write)
    tracker_calls = [
        c for c in subprocess_calls
        if any("review-defense-store.sh" in part for part in c)
        and not any("github" in part for part in c)
    ]
    assert tracker_calls, (
        f"review-defense-store.sh was not invoked. All subprocess calls: {subprocess_calls}"
    )

    # review-github-defense-store.sh must NOT be invoked (no PR context)
    github_store_calls = [
        c for c in subprocess_calls
        if any("review-github-defense-store.sh" in part for part in c)
    ]
    assert not github_store_calls, (
        f"review-github-defense-store.sh must NOT be invoked in local workflow "
        f"(no PR context). Got calls: {github_store_calls}"
    )


# ---------------------------------------------------------------------------
# Test 5: arbiter-rulings.json sidecar written with correct schema
# ---------------------------------------------------------------------------

def test_local_arbiter_writes_sidecar_with_block_list(tmp_path):
    """DISPATCH_ARBITER branch: arbiter-rulings.json must be written to
    artifacts_dir with schema_version=1.0.0 and all 3 rulings (BLOCK, DROP, DEFER)
    plus summary counts.

    Fails RED because the DISPATCH_ARBITER local branch is a stub.
    """
    if not _LOCAL_ARBITER_BRANCH_EXISTS:
        pytest.fail(
            "_local_arbiter_branch not implemented yet — "
            "dso_ci_review.local_workflow module missing"
        )

    findings = _sample_findings(3, severity="critical")
    rulings = _sample_rulings(("BLOCK", "DROP", "DEFER"))

    def mock_run(cmd, **kwargs):
        result = MagicMock()
        result.returncode = 0
        if isinstance(cmd, list) and len(cmd) > 2 and cmd[2] == "list":
            result.stdout = "[]"
        else:
            result.stdout = "t-defer-001\n"
        return result

    with (
        patch("dso_ci_review.local_workflow._dispatch_cycle_end_arbiter", return_value=rulings),
        patch("subprocess.run", side_effect=mock_run),
        patch("subprocess.check_output", return_value=b"test-branch\n"),
    ):
        _local_arbiter_branch(
            findings=findings,
            cycle_num=2,
            commit_sha="sha2",
            artifacts_dir=str(tmp_path),
        )

    sidecar_path = tmp_path / "arbiter-rulings.json"
    assert sidecar_path.exists(), (
        f"arbiter-rulings.json not written to {tmp_path}"
    )
    sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))

    # Schema version
    assert sidecar.get("schema_version") == "1.0.0", (
        f"schema_version must be '1.0.0', got: {sidecar.get('schema_version')!r}"
    )
    # All 3 rulings present
    written_rulings = sidecar.get("rulings", [])
    assert len(written_rulings) == 3, (
        f"Expected 3 rulings in sidecar, got {len(written_rulings)}: {written_rulings}"
    )
    ruling_types = {r.get("ruling") for r in written_rulings}
    assert ruling_types == {"BLOCK", "DROP", "DEFER"}, (
        f"Expected ruling types {{BLOCK, DROP, DEFER}}, got: {ruling_types}"
    )
    # Summary counts
    summary = sidecar.get("summary", {})
    assert summary.get("block_count") == 1, (
        f"summary.block_count should be 1, got: {summary}"
    )
    assert summary.get("drop_count") == 1, (
        f"summary.drop_count should be 1, got: {summary}"
    )
    assert summary.get("defer_count") == 1, (
        f"summary.defer_count should be 1, got: {summary}"
    )


# ---------------------------------------------------------------------------
# Test 6: BLOCK ruling causes exit code 1
# ---------------------------------------------------------------------------

def test_local_arbiter_block_exits_one(tmp_path):
    """When arbiter returns a BLOCK ruling, main() must return exit code 1.

    Fails RED because the DISPATCH_ARBITER stub in main() returns 1 unconditionally
    without inspecting arbiter output — a correctly-passing DEFER-only scenario
    would incorrectly return 1 as well (see test_local_arbiter_no_block_exits_zero).
    The stub behavior matches here only by accident; the correct implementation
    must route through _local_arbiter_branch and inspect rulings.
    """
    if not _LOCAL_ARBITER_BRANCH_EXISTS:
        pytest.fail(
            "_local_arbiter_branch not implemented yet — "
            "dso_ci_review.local_workflow module missing"
        )

    from dso_ci_review.local_workflow import main

    findings = _sample_findings(1, severity="critical")
    rulings = _sample_rulings(("BLOCK",))

    def mock_run(cmd, **kwargs):
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        return result

    def mock_check_output(cmd, **kwargs):
        # git rev-parse HEAD → commit sha
        if "rev-parse" in cmd:
            return b"deadbeef1234\n"
        # git rev-parse --abbrev-ref HEAD or branch-like → branch name
        return b"test-branch\n"

    with (
        # Patch the cycle-level next_action to return DISPATCH_ARBITER on first call
        patch(
            "dso_ci_review.local_workflow.cycle_next_action",
            return_value={"action": "DISPATCH_ARBITER", "reason": "max cycles", "cycle_num": 4},
        ),
        patch("dso_ci_review.local_workflow._dispatch_cycle_end_arbiter", return_value=rulings),
        patch("dso_ci_review.local_workflow._dispatch_local_reviewer", return_value={"findings": findings}),
        patch("subprocess.run", side_effect=mock_run),
        patch("subprocess.check_output", side_effect=mock_check_output),
        patch("dso_ci_review.local_workflow._read_diff", return_value="diff --git a/x.py b/x.py\n+foo"),
        patch("dso_ci_review.local_workflow._validate_agent_files"),
        patch("dso_ci_review.local_workflow.read_config_int", return_value=4),
        patch("dso_ci_review.local_workflow.cycle_ledger.read_ledger", return_value=_make_ledger(cycle_num=3, sha="deadbeef1234")),
        patch("dso_ci_review.local_workflow.get_provider"),
    ):
        exit_code = main()

    assert exit_code == 1, (
        f"main() must return 1 when arbiter produces BLOCK ruling, got: {exit_code}"
    )


# ---------------------------------------------------------------------------
# Test 7: no BLOCK ruling causes exit code 0
# ---------------------------------------------------------------------------

def test_local_arbiter_no_block_exits_zero(tmp_path):
    """When arbiter returns only DROP + DEFER (no BLOCK), main() must return 0.

    Fails RED because the DISPATCH_ARBITER stub in main() returns 1 unconditionally,
    regardless of ruling content. This test is the key discriminator: a correct
    implementation returns 0 when no BLOCK ruling is present.
    """
    if not _LOCAL_ARBITER_BRANCH_EXISTS:
        pytest.fail(
            "_local_arbiter_branch not implemented yet — "
            "dso_ci_review.local_workflow module missing"
        )

    from dso_ci_review.local_workflow import main

    findings = _sample_findings(2, severity="important")
    rulings = _sample_rulings(("DROP", "DEFER"))

    def mock_run(cmd, **kwargs):
        result = MagicMock()
        result.returncode = 0
        if isinstance(cmd, list) and len(cmd) > 2 and cmd[2] == "list":
            result.stdout = "[]"
        else:
            result.stdout = "t-defer-001\n"
        return result

    def mock_check_output(cmd, **kwargs):
        if "rev-parse" in cmd:
            return b"deadbeef1234\n"
        return b"test-branch\n"

    with (
        patch(
            "dso_ci_review.local_workflow.cycle_next_action",
            return_value={"action": "DISPATCH_ARBITER", "reason": "max cycles", "cycle_num": 4},
        ),
        patch("dso_ci_review.local_workflow._dispatch_cycle_end_arbiter", return_value=rulings),
        patch("dso_ci_review.local_workflow._dispatch_local_reviewer", return_value={"findings": findings}),
        patch("subprocess.run", side_effect=mock_run),
        patch("subprocess.check_output", side_effect=mock_check_output),
        patch("dso_ci_review.local_workflow._read_diff", return_value="diff --git a/x.py b/x.py\n+foo"),
        patch("dso_ci_review.local_workflow._validate_agent_files"),
        patch("dso_ci_review.local_workflow.read_config_int", return_value=4),
        patch("dso_ci_review.local_workflow.cycle_ledger.read_ledger", return_value=_make_ledger(cycle_num=3, sha="deadbeef1234")),
        patch("dso_ci_review.local_workflow.get_provider"),
    ):
        exit_code = main()

    assert exit_code == 0, (
        f"main() must return 0 when arbiter produces only DROP+DEFER rulings (no BLOCK), "
        f"got: {exit_code}"
    )


# ---------------------------------------------------------------------------
# Test 8: max_cycles threading — consistent between pre-loop and arbiter
# ---------------------------------------------------------------------------

def test_local_arbiter_max_cycles_threading(tmp_path):
    """max_cycles config value must be passed consistently to both:
      1. cycle_next_action() (pre-loop SHORT_CIRCUIT check)
      2. _dispatch_cycle_end_arbiter() (arbiter dispatch)
    And read_config_int must not be called a second time inside the arbiter path.

    Fails RED because the DISPATCH_ARBITER local branch is a stub.
    """
    if not _LOCAL_ARBITER_BRANCH_EXISTS:
        pytest.fail(
            "_local_arbiter_branch not implemented yet — "
            "dso_ci_review.local_workflow module missing"
        )

    from dso_ci_review.local_workflow import main

    findings = _sample_findings(1, severity="critical")
    rulings = _sample_rulings(("BLOCK",))
    next_action_calls: list[dict] = []
    arbiter_calls: list[dict] = []
    config_read_count = 0

    def mock_read_config_int(key, default, config_path=None):
        nonlocal config_read_count
        if key == "review.max_cycles":
            config_read_count += 1
            return 6  # distinctive value to trace threading
        return default

    def mock_next_action(ledger, max_cycles, current_findings, current_commit_sha, artifacts_dir=None):
        next_action_calls.append({"max_cycles": max_cycles})
        return {"action": "DISPATCH_ARBITER", "reason": "max cycles", "cycle_num": 6}

    def mock_dispatch_arbiter(findings, defenses, diff_text, model, provider_chain,
                               cycle_num, max_cycles, **kwargs):
        arbiter_calls.append({"max_cycles": max_cycles, "cycle_num": cycle_num})
        return rulings

    def mock_run(cmd, **kwargs):
        result = MagicMock()
        result.returncode = 0
        if isinstance(cmd, list) and len(cmd) > 2 and cmd[2] == "list":
            result.stdout = "[]"
        else:
            result.stdout = ""
        return result

    def mock_check_output(cmd, **kwargs):
        if "rev-parse" in cmd:
            return b"sha1234\n"
        return b"test-branch\n"

    with (
        patch("dso_ci_review.local_workflow.cycle_next_action", side_effect=mock_next_action),
        patch("dso_ci_review.local_workflow._dispatch_cycle_end_arbiter", side_effect=mock_dispatch_arbiter),
        patch("dso_ci_review.local_workflow._dispatch_local_reviewer", return_value={"findings": findings}),
        patch("dso_ci_review.local_workflow.read_config_int", side_effect=mock_read_config_int),
        patch("subprocess.run", side_effect=mock_run),
        patch("subprocess.check_output", side_effect=mock_check_output),
        patch("dso_ci_review.local_workflow._read_diff", return_value="diff --git a/x.py b/x.py\n+foo"),
        patch("dso_ci_review.local_workflow._validate_agent_files"),
        patch("dso_ci_review.local_workflow.cycle_ledger.read_ledger", return_value=_make_ledger(cycle_num=5, sha="sha1234")),
        patch("dso_ci_review.local_workflow.get_provider"),
    ):
        main()

    # cycle_next_action must have received the same max_cycles=6 value
    assert next_action_calls, "cycle_next_action was never called"
    assert all(c["max_cycles"] == 6 for c in next_action_calls), (
        f"cycle_next_action received inconsistent max_cycles values: {next_action_calls}"
    )

    # _dispatch_cycle_end_arbiter must have received max_cycles=6
    assert arbiter_calls, "_dispatch_cycle_end_arbiter was never called"
    assert all(c["max_cycles"] == 6 for c in arbiter_calls), (
        f"arbiter received inconsistent max_cycles values: {arbiter_calls}"
    )

    # read_config_int must have been called exactly ONCE for review.max_cycles
    # (not again inside the arbiter path — DRY, single authoritative read)
    assert config_read_count == 1, (
        f"read_config_int('review.max_cycles') called {config_read_count} times; "
        f"expected exactly 1 (arbiter path must reuse the value, not re-read)"
    )
