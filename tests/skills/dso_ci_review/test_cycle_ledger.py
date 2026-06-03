"""RED tests for dso_ci_review.cycle_ledger — read/write/append + reconstruct.

All tests fail until cycle_ledger.py is created (Story 45da-5043 T3).

RED marker: tests/skills/dso_ci_review/test_cycle_ledger.py [test_read_ledger_returns_empty_when_file_absent]
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import threading
import time
from unittest.mock import patch

import pytest  # noqa: F401  (kept for fixture discovery / future markers)

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# Importing the not-yet-existing module — every test fails with
# ModuleNotFoundError until T3 lands cycle_ledger.py.
from dso_ci_review.cycle_ledger import (  # noqa: E402
    append_cycle,
    read_ledger,
    reconstruct_from_pr_comments,
    write_ledger,
)


def test_read_ledger_returns_empty_when_file_absent(tmp_path):
    """Given: nonexistent path.
    When: read_ledger(path) is called.
    Then: returns empty v1.2.0 schema.
    """
    result = read_ledger(str(tmp_path / "nonexistent.json"))
    assert result["schema_version"] == "1.2.0", (
        f"Expected schema_version '1.2.0', got {result.get('schema_version')!r}"
    )
    assert result["epic_id"] == "", (
        f"Expected empty epic_id, got {result.get('epic_id')!r}"
    )
    assert result["cycles"] == [], (
        f"Expected empty cycles list, got {result.get('cycles')!r}"
    )


def test_write_and_read_round_trip_v1_1_0(tmp_path):
    """Given: a v1.1.0 ledger with findings tuples + commit_sha.
    When: write_ledger then read_ledger.
    Then: returned ledger equals the written ledger (round-trip fidelity).
    """
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "test-epic",
        "cycles": [
            {
                "cycle_num": 1,
                "timestamp_utc": "2026-05-17T10:00:00Z",
                "commit_sha": "abc123" + "0" * 34,
                "findings": [["src/x.py", "10-20", "correctness"]],
                "findings_hash": "h1",
                "halt_reason": None,
            }
        ],
    }
    path = str(tmp_path / "ledger.json")
    write_ledger(path, ledger)
    result = read_ledger(path)
    assert result == ledger, (
        f"Round-trip mismatch.\nWrote: {ledger!r}\nRead:  {result!r}"
    )


def test_append_cycle_increments_cycles_array(tmp_path):
    """Given: a ledger with one existing cycle.
    When: append_cycle is called with new cycle data.
    Then: ledger now has 2 cycles and the new entry has all fields populated.
    """
    path = str(tmp_path / "ledger.json")
    initial = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 1,
                "timestamp_utc": "t1",
                "commit_sha": "s1",
                "findings": [],
                "findings_hash": "h1",
                "halt_reason": None,
            }
        ],
    }
    write_ledger(path, initial)
    append_cycle(
        path,
        cycle_num=2,
        findings_tuples=[["x.py", "1", "c"]],
        commit_sha="s2" + "0" * 38,
        findings_hash="h2",
        pr_number=42,
    )
    result = read_ledger(path)
    assert len(result["cycles"]) == 2, (
        f"Expected 2 cycles after append, got {len(result['cycles'])}"
    )
    cycle2 = result["cycles"][1]
    assert cycle2["cycle_num"] == 2, (
        f"Expected appended cycle_num=2, got {cycle2.get('cycle_num')!r}"
    )
    assert cycle2["commit_sha"].startswith("s2"), (
        f"Expected commit_sha to start with 's2', got {cycle2.get('commit_sha')!r}"
    )
    assert cycle2["findings"] == [["x.py", "1", "c"]], (
        f"Expected findings tuple, got {cycle2.get('findings')!r}"
    )
    assert cycle2["findings_hash"] == "h2", (
        f"Expected findings_hash='h2', got {cycle2.get('findings_hash')!r}"
    )


def test_read_v1_0_0_ledger_backward_compat(tmp_path):
    """Given: a v1.0.0 ledger (no findings/commit_sha fields on cycles).
    When: read_ledger is called.
    Then: ledger reads without crash; v1.0.0 cycles intact; missing fields default sensibly.
    """
    path = str(tmp_path / "ledger.json")
    old_ledger = {
        "schema_version": "1.0.0",
        "epic_id": "e1",
        "cycles": [{"cycle_num": 1, "timestamp_utc": "t1", "findings_hash": "h1"}],
    }
    pathlib.Path(path).write_text(json.dumps(old_ledger))
    result = read_ledger(path)
    assert result["cycles"][0]["cycle_num"] == 1, (
        f"v1.0.0 cycle_num lost on read: {result['cycles'][0]!r}"
    )
    # Reader must not crash on missing extended fields. If reader normalizes,
    # missing fields default to empty / null. If reader preserves verbatim,
    # the fields are simply absent. Either is acceptable RED-spec behavior.
    cycle = result["cycles"][0]
    assert cycle.get("findings", []) == [], (
        f"Missing findings should default to empty list, got {cycle.get('findings')!r}"
    )
    assert cycle.get("commit_sha", "") == "", (
        f"Missing commit_sha should default to empty string, got {cycle.get('commit_sha')!r}"
    )


def test_reconstruct_from_pr_comments_parses_extended_marker():
    """Given: PR comment with extended DSO-Review-Cycle marker (commit_sha + tuples).
    When: reconstruct_from_pr_comments is called.
    Then: returned ledger has one cycle with all fields parsed (including findings tuples).
    """
    fake_comment = (
        "Review for cycle 1\n"
        "DSO-Review-Cycle: 1 commit_sha=abc123def4 findings_hash=h1 "
        'tuples=[["src/x.py","10-20","correctness"]]\n'
    )
    fake_response = json.dumps([{"body": fake_comment}])
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.stdout = fake_response
        mock_run.return_value.returncode = 0
        ledger = reconstruct_from_pr_comments(42, "owner/repo")
    assert len(ledger["cycles"]) == 1, (
        f"Expected 1 reconstructed cycle, got {len(ledger['cycles'])}"
    )
    cycle = ledger["cycles"][0]
    assert cycle["cycle_num"] == 1, (
        f"Expected cycle_num=1, got {cycle.get('cycle_num')!r}"
    )
    assert cycle["commit_sha"] == "abc123def4", (
        f"Expected commit_sha='abc123def4', got {cycle.get('commit_sha')!r}"
    )
    assert cycle["findings"] == [["src/x.py", "10-20", "correctness"]], (
        f"Expected findings tuple, got {cycle.get('findings')!r}"
    )


def test_reconstruct_tolerates_legacy_marker_format():
    """Given: PR comment with v1.0.0 DSO-Review-Cycle marker (no commit_sha/tuples).
    When: reconstruct_from_pr_comments is called.
    Then: a cycle entry is produced without findings/commit_sha (graceful degrade, no crash).
    """
    legacy_comment = "Review\nDSO-Review-Cycle: 1 findings-hash=h1\nDone"
    fake_response = json.dumps([{"body": legacy_comment}])
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.stdout = fake_response
        mock_run.return_value.returncode = 0
        ledger = reconstruct_from_pr_comments(42, "owner/repo")
    assert len(ledger["cycles"]) == 1, (
        f"Expected 1 legacy-format cycle, got {len(ledger['cycles'])}"
    )
    cycle = ledger["cycles"][0]
    assert cycle["cycle_num"] == 1, (
        f"Expected cycle_num=1 from legacy marker, got {cycle.get('cycle_num')!r}"
    )
    assert cycle.get("findings", []) == [], (
        f"Legacy marker should yield empty findings, got {cycle.get('findings')!r}"
    )
    assert cycle.get("commit_sha", "") == "", (
        f"Legacy marker should yield empty commit_sha, got {cycle.get('commit_sha')!r}"
    )


def test_reconstruct_clean_v12_marker_has_no_gaps():
    """Regression guard for bug 9788 fix scope: a successfully parsed v1.2.0
    marker must NOT set reconstruction_gaps=True.

    The refactor to use parse_cycle_marker() (commit 3 of the bug 9788 PR)
    initially left a stray `has_gaps = True` line in the success branch,
    which caused reconstruction_gaps to be True even for fully successful
    reconstructions. This test locks that regression down.
    """
    clean_comment = (
        "DSO-Review-Cycle: 1 pr_number=42 commit_sha=abc findings_hash=h1 "
        'tuples=[["x.py","1","c"]]\n'
    )
    fake_response = json.dumps([{"body": clean_comment}])
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.stdout = fake_response
        mock_run.return_value.returncode = 0
        ledger = reconstruct_from_pr_comments(42, "owner/repo")
    assert len(ledger["cycles"]) == 1, (
        f"Expected 1 reconstructed cycle, got {len(ledger['cycles'])}"
    )
    assert not ledger.get("reconstruction_gaps"), (
        "Clean reconstruction must not flag gaps; got "
        f"reconstruction_gaps={ledger.get('reconstruction_gaps')!r}"
    )


def test_reconstruct_clean_v11_marker_has_no_gaps():
    """Sibling regression guard for v1.1.0 markers (bug 9788 fix)."""
    clean_comment = (
        "DSO-Review-Cycle: 1 commit_sha=abc findings_hash=h1 "
        'tuples=[["x.py","1","c"]]\n'
    )
    fake_response = json.dumps([{"body": clean_comment}])
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.stdout = fake_response
        mock_run.return_value.returncode = 0
        ledger = reconstruct_from_pr_comments(42, "owner/repo")
    assert len(ledger["cycles"]) == 1
    assert not ledger.get("reconstruction_gaps"), (
        "Clean v1.1.0 reconstruction must not flag gaps; got "
        f"reconstruction_gaps={ledger.get('reconstruction_gaps')!r}"
    )


def test_reconstruct_malformed_marker_logged_skipped(capsys):
    """Given: a comment block with one malformed and one valid DSO-Review-Cycle marker.
    When: reconstruct_from_pr_comments is called.
    Then: malformed entry is skipped, warning is logged, valid entry is still parsed.
    """
    mixed = (
        "DSO-Review-Cycle: not-a-number commit_sha=x findings_hash=h tuples=[]\n"
        "DSO-Review-Cycle: 2 commit_sha=valid findings_hash=h2 "
        'tuples=[["x.py","1","c"]]\n'
    )
    fake_response = json.dumps([{"body": mixed}])
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.stdout = fake_response
        mock_run.return_value.returncode = 0
        ledger = reconstruct_from_pr_comments(42, "owner/repo")
    cycle_nums = [c["cycle_num"] for c in ledger["cycles"]]
    assert 2 in cycle_nums, (
        f"Valid cycle 2 should be preserved, got cycle_nums={cycle_nums!r}"
    )
    assert "not-a-number" not in cycle_nums, (
        f"Malformed cycle_num should be skipped, got cycle_nums={cycle_nums!r}"
    )


def test_concurrent_shell_and_python_writers_coordinate_on_lockfile(tmp_path):
    """Given: a shell writer holds fcntl.LOCK_EX on $ARTIFACTS_DIR/cycle-ledger.lock.
    When: cycle_ledger.append_cycle is invoked concurrently.
    Then: Python writer waits for the lock, then appends without overwriting the
          shell writer's entry. Lock path is exactly $ARTIFACTS_DIR/cycle-ledger.lock
          (not a Python-private lock path).
    """
    ledger_path = str(tmp_path / "cycle-ledger.json")
    lock_path = tmp_path / "cycle-ledger.lock"
    write_ledger(
        ledger_path,
        {"schema_version": "1.1.0", "epic_id": "e1", "cycles": []},
    )
    # Spawn shell holding the lock for ~0.5s on the EXACT expected lock path.
    shell_cmd = f"exec 9>{lock_path}; flock 9; sleep 0.5; exec 9>&-"
    proc = subprocess.Popen(["bash", "-c", shell_cmd])
    try:
        time.sleep(0.1)  # let shell acquire the lock
        assert lock_path.exists(), (
            f"Shell writer did not create lock file at {lock_path} — "
            "Python module must use $ARTIFACTS_DIR/cycle-ledger.lock, "
            "not a Python-private path."
        )
        start = time.time()
        append_cycle(
            ledger_path,
            cycle_num=1,
            findings_tuples=[["x.py", "1", "c"]],
            commit_sha="s" * 40,
            findings_hash="h1",
            pr_number=42,
        )
        elapsed = time.time() - start
    finally:
        proc.wait()
    assert elapsed >= 0.3, (
        f"Python writer did not wait for shell-held lock (elapsed={elapsed:.3f}s); "
        "expected ≥0.3s. Python writer is likely using a different lock path."
    )
    # Verify Python writer's entry landed without overwriting shell's pre-existing
    # ledger state (we pre-seeded an empty cycles list; Python should add one entry).
    final = read_ledger(ledger_path)
    assert len(final["cycles"]) == 1, (
        f"Expected exactly 1 cycle after concurrent write, got {len(final['cycles'])}"
    )
    assert final["cycles"][0]["cycle_num"] == 1, (
        f"Python-appended cycle missing or mangled: {final['cycles']!r}"
    )


def test_append_atomic_write_no_corruption_on_concurrent_appends(tmp_path):
    """Given: two threads concurrently calling append_cycle on the same ledger.
    When: both appends run to completion.
    Then: final ledger has exactly 2 cycles (both visible, no overwrite, no corruption).
    """
    ledger_path = str(tmp_path / "cycle-ledger.json")
    write_ledger(
        ledger_path,
        {"schema_version": "1.1.0", "epic_id": "e1", "cycles": []},
    )

    def do_append(n: int) -> None:
        append_cycle(
            ledger_path,
            cycle_num=n,
            findings_tuples=[[f"f{n}.py", "1", "c"]],
            commit_sha=f"sha{n}" + "0" * 36,
            findings_hash=f"h{n}",
            pr_number=42,
        )

    t1 = threading.Thread(target=do_append, args=(1,))
    t2 = threading.Thread(target=do_append, args=(2,))
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    result = read_ledger(ledger_path)
    assert len(result["cycles"]) == 2, (
        f"Expected 2 cycles after concurrent appends, got {len(result['cycles'])} — "
        "atomic-write contract violated (one writer overwrote the other)."
    )
    cycle_nums = sorted(c["cycle_num"] for c in result["cycles"])
    assert cycle_nums == [1, 2], (
        f"Expected cycle_nums [1, 2] after concurrent appends, got {cycle_nums!r}"
    )


# ── Bug da45 PR #202 finding f-f6g7h8i9 — _cli_main test coverage ─────────────


def test_cli_main_missing_args_returns_usage_exit_code():
    """_cli_main with no args prints usage and returns exit code 2."""
    from dso_ci_review.cycle_ledger import _cli_main

    rc = _cli_main(["cycle_ledger"])
    assert rc == 2


def test_cli_main_non_integer_pr_returns_error(capsys):
    """_cli_main rejects non-integer PR number with exit code 2 + stderr."""
    from dso_ci_review.cycle_ledger import _cli_main

    rc = _cli_main(
        ["cycle_ledger", "reconstruct-from-pr", "not-a-number", "owner/repo"]
    )
    captured = capsys.readouterr()
    assert rc == 2
    assert "integer" in captured.err.lower()


def test_cli_main_invokes_reconstruct(monkeypatch, capsys):
    """_cli_main with valid args delegates to reconstruct_from_pr_comments
    and emits the ledger JSON on stdout."""
    from dso_ci_review import cycle_ledger as cl

    called_with = {}

    def fake_reconstruct(pr_num, repo):
        called_with["pr_num"] = pr_num
        called_with["repo"] = repo
        return {"schema_version": "1.1.0", "epic_id": "", "cycles": []}

    monkeypatch.setattr(cl, "reconstruct_from_pr_comments", fake_reconstruct)
    rc = cl._cli_main(["cycle_ledger", "reconstruct-from-pr", "42", "owner/repo"])
    captured = capsys.readouterr()
    assert rc == 0
    assert called_with == {"pr_num": 42, "repo": "owner/repo"}
    # Stdout should be valid JSON describing the ledger
    import json as _json

    parsed = _json.loads(captured.out)
    assert parsed["cycles"] == []


# ── Bug da45 PR #202 finding f-XXX — _atomic_write cleanup path ───────────────


def test_atomic_write_cleans_up_temp_on_replace_failure(monkeypatch, tmp_path):
    """_atomic_write must unlink its temp file when os.replace fails.

    Simulate: write succeeds, replace raises OSError (e.g., cross-device link).
    Assert: (1) raised, (2) no temp file leftover in the destination dir.
    """
    from dso_ci_review.cycle_ledger import _atomic_write

    target = tmp_path / "ledger.json"

    real_replace = os.replace

    def failing_replace(src, dst):
        # Mimic an EXDEV (cross-device) or permission error mid-replace.
        raise OSError("simulated replace failure")

    monkeypatch.setattr(os, "replace", failing_replace)
    try:
        _atomic_write(str(target), "{}")
    except OSError as e:
        assert "simulated" in str(e)
    else:
        raise AssertionError("_atomic_write should have re-raised the failure")
    monkeypatch.setattr(os, "replace", real_replace)

    # No temp file should remain in tmp_path
    leftovers = [p for p in tmp_path.iterdir() if p.name != "ledger.json"]
    assert not leftovers, (
        f"_atomic_write left temp file(s) behind after replace failure: "
        f"{[p.name for p in leftovers]}"
    )


# ── Bug 230d-6cab — reconstruct_from_pr_comments uses wrong gh-api endpoint ──


def test_reconstruct_uses_issues_endpoint_not_pulls_endpoint():
    """Bug 230d-6cab: reconstruct_from_pr_comments must call the
    /issues/{n}/comments endpoint, NOT /pulls/{n}/comments.

    gh pr comment (the writer) posts to the issue-conversation endpoint.
    The reader was calling the review-thread endpoint, so the two sets are
    disjoint and reconstruction never sees any markers.

    This test inspects the cmd passed to subprocess.run — the observable
    boundary between the function and the gh CLI.  It MUST fail today
    (current code uses /pulls/) and pass after the Approach-B fix.
    """
    import json as _json

    fake_response = _json.dumps([])
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.stdout = fake_response
        mock_run.return_value.returncode = 0
        reconstruct_from_pr_comments(42, "owner/repo")

    assert mock_run.called, "subprocess.run was never called"
    cmd = mock_run.call_args[0][0]  # positional first arg is the cmd list

    issues_endpoint = "repos/owner/repo/issues/42/comments"
    pulls_endpoint = "repos/owner/repo/pulls/42/comments"

    assert issues_endpoint in cmd, (
        f"Expected cmd to contain '{issues_endpoint}' (issues/conversation endpoint), "
        f"but got cmd={cmd!r}"
    )
    assert pulls_endpoint not in cmd, (
        f"cmd must NOT contain '{pulls_endpoint}' (review-thread endpoint), "
        f"but got cmd={cmd!r}"
    )


# ── Bug adea-5dfc — error-branch coverage for reconstruct_from_pr_comments ───


def test_reconstruct_gh_api_failure_sets_reconstruction_gaps(capsys):
    """Given: subprocess.run raises CalledProcessError (gh API failure).
    When: reconstruct_from_pr_comments is called.
    Then: returned ledger has reconstruction_gaps=True and WARNING emitted to stderr.
    """
    with patch("subprocess.run") as mock_run:
        mock_run.side_effect = subprocess.CalledProcessError(
            1, "gh", stderr="auth error"
        )
        ledger = reconstruct_from_pr_comments(42, "owner/repo")
    assert ledger.get("reconstruction_gaps") is True, (
        f"Expected reconstruction_gaps=True on CalledProcessError, "
        f"got reconstruction_gaps={ledger.get('reconstruction_gaps')!r}"
    )
    captured = capsys.readouterr()
    assert "WARNING" in captured.err, (
        f"Expected 'WARNING' in stderr, got: {captured.err!r}"
    )


def test_reconstruct_gh_not_installed_sets_reconstruction_gaps(capsys):
    """Given: subprocess.run raises FileNotFoundError (gh CLI missing).
    When: reconstruct_from_pr_comments is called.
    Then: returned ledger has reconstruction_gaps=True and diagnostic emitted to stderr.
    """
    with patch("subprocess.run") as mock_run:
        mock_run.side_effect = FileNotFoundError
        ledger = reconstruct_from_pr_comments(42, "owner/repo")
    assert ledger.get("reconstruction_gaps") is True, (
        f"Expected reconstruction_gaps=True on FileNotFoundError, "
        f"got reconstruction_gaps={ledger.get('reconstruction_gaps')!r}"
    )
    captured = capsys.readouterr()
    assert "gh CLI is not installed" in captured.err, (
        f"Expected 'gh CLI is not installed' in stderr, got: {captured.err!r}"
    )


def test_reconstruct_json_decode_error_sets_reconstruction_gaps(capsys):
    """Given: subprocess.run returns non-JSON stdout.
    When: reconstruct_from_pr_comments is called.
    Then: returned ledger has reconstruction_gaps=True and parse-error warning in stderr.
    """
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.stdout = "not-valid-json"
        mock_run.return_value.returncode = 0
        ledger = reconstruct_from_pr_comments(42, "owner/repo")
    assert ledger.get("reconstruction_gaps") is True, (
        f"Expected reconstruction_gaps=True on JSONDecodeError, "
        f"got reconstruction_gaps={ledger.get('reconstruction_gaps')!r}"
    )
    captured = capsys.readouterr()
    assert "not valid JSON" in captured.err, (
        f"Expected 'not valid JSON' in stderr, got: {captured.err!r}"
    )


def test_reconstruct_endpoint_matches_shared_helper():
    """Bug 230d-6cab writer/reader parity contract (Approach B).

    The helper cycle_marker_list_endpoint does not exist yet — this import
    will raise ImportError in the RED phase.  After the fix the helper exists
    and both assertions must hold:
      1. The helper returns the canonical issues-endpoint string.
      2. reconstruct_from_pr_comments passes that exact string to gh.

    Do NOT mock the helper: the contract is that both reference the same
    string, not merely that the function calls the helper internally.
    """
    import json as _json

    # This import is the RED trigger: ImportError until the helper is added.
    from dso_ci_review.cycle_marker_format import cycle_marker_list_endpoint

    expected_endpoint = cycle_marker_list_endpoint("owner/repo", 42)
    assert expected_endpoint == "repos/owner/repo/issues/42/comments", (
        f"Helper returned unexpected endpoint: {expected_endpoint!r}"
    )

    fake_response = _json.dumps([])
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.stdout = fake_response
        mock_run.return_value.returncode = 0
        reconstruct_from_pr_comments(42, "owner/repo")

    assert mock_run.called, "subprocess.run was never called"
    cmd = mock_run.call_args[0][0]

    assert expected_endpoint in cmd, (
        f"reconstruct_from_pr_comments must pass the shared helper's endpoint "
        f"'{expected_endpoint}' to gh, but got cmd={cmd!r}"
    )
