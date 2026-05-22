"""RED tests for dso_ci_review.arbiter_processor — process arbiter rulings into side effects.

All tests fail until arbiter_processor.py is created (Story b1b6 T4).
"""

from __future__ import annotations

import json
import pathlib
import sys
from unittest.mock import MagicMock, patch


_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.arbiter_processor import process_rulings  # noqa: E402


def _make_finding(
    idx=0, file="src/x.py", line="10-20", category="correctness", severity="critical"
):
    return {
        "file": file,
        "line_range": line,
        "category": category,
        "severity": severity,
        "finding_index": idx,
    }


def _make_ruling(idx=0, ruling="BLOCK", rationale="test rationale"):
    return {
        "ruling": ruling,
        "rationale": rationale,
        "schema_version": "1.0.0",
        "finding_index": idx,
        "impact_class": "bug",
    }


def test_process_rulings_accumulates_block(tmp_path):
    """BLOCK rulings accumulate in result['block'] list."""
    rulings = [
        _make_ruling(idx=0, ruling="BLOCK"),
        _make_ruling(idx=1, ruling="DROP"),
        _make_ruling(idx=2, ruling="BLOCK"),
    ]
    finding_map = {i: _make_finding(idx=i) for i in range(3)}
    result = process_rulings(
        rulings=rulings,
        finding_map=finding_map,
        cycle_num=1,
        commit_sha="abc123",
        artifacts_dir=str(tmp_path),
    )
    assert len(result["block"]) == 2


def test_process_rulings_defer_creates_orphan_ticket(tmp_path):
    """DEFER ruling triggers ticket create with correct tags + dedup marker."""
    rulings = [_make_ruling(idx=0, ruling="DEFER", rationale="Deferred per arbiter")]
    finding_map = {0: _make_finding(idx=0)}
    captured = []

    def mock_subprocess_run(cmd, **kwargs):
        captured.append(cmd)
        if cmd[1:3] == ["ticket", "list"]:
            # No existing tickets
            result = MagicMock()
            result.returncode = 0
            result.stdout = "[]"
            return result
        if cmd[1:4] == ["ticket", "create", "task"]:
            result = MagicMock()
            result.returncode = 0
            result.stdout = "t-new-001\n"
            return result
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        return result

    with patch("subprocess.run", side_effect=mock_subprocess_run):
        result = process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc123",
            pr_number=42,
            artifacts_dir=str(tmp_path),
        )
    # Verify ticket create call had correct args
    create_calls = [c for c in captured if c[1:4] == ["ticket", "create", "task"]]
    assert len(create_calls) >= 1
    create_cmd = create_calls[0]
    assert any("Deferred review finding:" in arg for arg in create_cmd)
    assert "--tags=orphan:deferred_review" in create_cmd
    assert "--tags=origin:arbiter" in create_cmd
    assert "--priority=3" in create_cmd
    assert "t-new-001" in result["defer_ticket_ids"]


def test_process_rulings_defer_idempotent_skips_existing_ticket(tmp_path):
    """Second DEFER call with same finding_hash + PR finds existing ticket and skips create."""
    rulings = [_make_ruling(idx=0, ruling="DEFER")]
    finding_map = {0: _make_finding(idx=0)}
    # Mock subprocess: ticket list returns an existing match

    def mock_subprocess_run(cmd, **kwargs):
        if cmd[1:3] == ["ticket", "list"]:
            result = MagicMock()
            result.returncode = 0
            # Existing ticket with matching marker
            result.stdout = json.dumps(
                [
                    {
                        "ticket_id": "t-existing-001",
                        "description": "Old defer. Finding-Hash: ANYHASH Scope: #42 ...",
                    }
                ]
            )
            return result
        # Should NOT reach create-task
        return MagicMock(returncode=0, stdout="")

    with patch("subprocess.run", side_effect=mock_subprocess_run):
        # First call generates finding_hash; second call should match
        process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            pr_number=42,
            artifacts_dir=str(tmp_path),
        )
    # Modify the marker pattern to use actual finding_hash for round 2
    # For now, assert that if the marker matches, second call hits dedup path
    # NOTE: The implementation will compute finding_hash and look for it in descriptions.
    # This RED test asserts the dedup PATH exists; the actual hash match logic is in T4.
    # Mark test as "expects ticket create was NOT called" via a stricter mock
    captured_creates = []

    def mock_strict(cmd, **kwargs):
        if cmd[1:4] == ["ticket", "create", "task"]:
            captured_creates.append(cmd)
        if cmd[1:3] == ["ticket", "list"]:
            # Return existing with proper hash marker
            from hashlib import sha256

            f = finding_map[0]
            h = sha256(
                f"{f['file']}|{f['line_range']}|{f['category']}".encode()
            ).hexdigest()[:16]
            result = MagicMock()
            result.returncode = 0
            result.stdout = json.dumps(
                [
                    {
                        "ticket_id": "t-existing-001",
                        "description": f"Old defer. Finding-Hash: {h} Scope: #42 ...",
                    }
                ]
            )
            return result
        return MagicMock(returncode=0, stdout="")

    with patch("subprocess.run", side_effect=mock_strict):
        result2 = process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=2,
            commit_sha="def",
            pr_number=42,
            artifacts_dir=str(tmp_path),
        )
    assert len(captured_creates) == 0, (
        "ticket create should not be called when dedup hits"
    )
    assert "t-existing-001" in result2["defer_ticket_ids"]


def test_process_rulings_drop_writes_dual_store_when_pr_number_set(tmp_path):
    """DROP ruling with PR_NUMBER → both tracker (review-defense-store.sh) AND PR (review-github-defense-store.sh)."""
    rulings = [_make_ruling(idx=0, ruling="DROP", rationale="Defense accepted")]
    finding_map = {0: _make_finding(idx=0)}
    captured = []

    def mock_subprocess_run(cmd, **kwargs):
        captured.append(cmd)
        return MagicMock(returncode=0, stdout="")

    with patch("subprocess.run", side_effect=mock_subprocess_run):
        process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            pr_number=42,
            artifacts_dir=str(tmp_path),
        )
    # Both store calls observed
    tracker_calls = [
        c for c in captured if any("review-defense-store.sh" in str(a) for a in c)
    ]
    pr_store_calls = [
        c
        for c in captured
        if any("review-github-defense-store.sh" in str(a) for a in c)
    ]
    assert len(tracker_calls) >= 1, "tracker store write expected"
    assert len(pr_store_calls) >= 1, "PR store write expected when PR_NUMBER set"


def test_process_rulings_drop_skips_pr_store_when_pr_number_absent(tmp_path):
    """DROP ruling with PR_NUMBER=None (local mode) → only tracker, no PR store call."""
    rulings = [_make_ruling(idx=0, ruling="DROP")]
    finding_map = {0: _make_finding(idx=0)}
    captured = []

    def mock_subprocess_run(cmd, **kwargs):
        captured.append(cmd)
        return MagicMock(returncode=0, stdout="")

    with patch("subprocess.run", side_effect=mock_subprocess_run):
        process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            pr_number=None,
            branch_name="story/local",
            artifacts_dir=str(tmp_path),
        )
    pr_store_calls = [
        c
        for c in captured
        if any("review-github-defense-store.sh" in str(a) for a in c)
    ]
    assert len(pr_store_calls) == 0, (
        "PR store should NOT be called when PR_NUMBER absent"
    )


def test_process_rulings_writes_arbiter_rulings_sidecar(tmp_path):
    """arbiter-rulings.json sidecar written atomically with schema_version + summary."""
    rulings = [
        _make_ruling(idx=0, ruling="BLOCK"),
        _make_ruling(idx=1, ruling="DEFER"),
        _make_ruling(idx=2, ruling="DROP"),
    ]
    finding_map = {i: _make_finding(idx=i) for i in range(3)}
    with patch(
        "subprocess.run", return_value=MagicMock(returncode=0, stdout="t-001\n")
    ):
        process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=2,
            commit_sha="abc123",
            pr_number=42,
            artifacts_dir=str(tmp_path),
        )
    sidecar = tmp_path / "arbiter-rulings.json"
    assert sidecar.exists()
    data = json.loads(sidecar.read_text())
    assert data["schema_version"] == "1.0.0"
    assert data["commit_sha"] == "abc123"
    assert data["cycle_num"] == 2
    assert "summary" in data
    assert data["summary"]["block_count"] == 1


def test_process_rulings_sidecar_overwrite_idempotent_on_same_sha(tmp_path):
    """Two calls with same commit_sha + same rulings produce byte-identical sidecar."""
    rulings = [_make_ruling(idx=0, ruling="BLOCK")]
    finding_map = {0: _make_finding(idx=0)}
    with patch("subprocess.run", return_value=MagicMock(returncode=0, stdout="")):
        process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            artifacts_dir=str(tmp_path),
        )
        first_content = (tmp_path / "arbiter-rulings.json").read_text()
        process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            artifacts_dir=str(tmp_path),
        )
        second_content = (tmp_path / "arbiter-rulings.json").read_text()
    assert first_content == second_content, (
        "Same input should produce byte-identical sidecar"
    )


def test_process_rulings_defer_dedup_uses_finding_hash_plus_pr_in_description(tmp_path):
    """Dedup query specifically uses finding_hash + PR scope marker in ticket description."""
    rulings = [_make_ruling(idx=0, ruling="DEFER")]
    finding_map = {
        0: _make_finding(idx=0, file="x.py", line="1-5", category="security")
    }
    from hashlib import sha256

    expected_hash = sha256(b"x.py|1-5|security").hexdigest()[:16]
    captured_creates = []

    def mock_subprocess_run(cmd, **kwargs):
        if cmd[1:4] == ["ticket", "create", "task"]:
            captured_creates.append(cmd)
        if cmd[1:3] == ["ticket", "list"]:
            # Existing ticket with exact marker
            result = MagicMock()
            result.returncode = 0
            result.stdout = json.dumps(
                [
                    {
                        "ticket_id": "t-match-001",
                        "description": f"Finding-Hash: {expected_hash} Scope: #99 some other text",
                    }
                ]
            )
            return result
        return MagicMock(returncode=0, stdout="")

    with patch("subprocess.run", side_effect=mock_subprocess_run):
        result = process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            pr_number=99,
            artifacts_dir=str(tmp_path),
        )
    assert len(captured_creates) == 0
    assert "t-match-001" in result["defer_ticket_ids"]


# AC-amendment tests (from gap analysis):


def test_arbiter_processor_drop_pr_store_failure_does_not_block(tmp_path, capsys):
    """When PR store write fails but tracker succeeded, no BLOCK escalation, no tracker rollback."""
    rulings = [_make_ruling(idx=0, ruling="DROP")]
    finding_map = {0: _make_finding(idx=0)}

    def mock_run(cmd, **kwargs):
        # tracker succeeds, PR store fails
        if any("review-github-defense-store.sh" in str(a) for a in cmd):
            return MagicMock(returncode=1, stdout="", stderr="GitHub API error")
        return MagicMock(returncode=0, stdout="")

    with patch("subprocess.run", side_effect=mock_run):
        result = process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            pr_number=42,
            artifacts_dir=str(tmp_path),
        )
    # Should NOT escalate to BLOCK
    assert len(result["block"]) == 0
    # Structured log should be emitted
    captured = capsys.readouterr()
    # accept either stderr message presence
    assert (
        "drop_pr_store_failed" in captured.err or "drop_pr_store_failed" in captured.out
    )


def test_arbiter_processor_handles_legacy_sidecar(tmp_path, capsys):
    """Legacy arbiter-rulings.json without schema_version is overwritten gracefully (log warning, don't crash)."""
    sidecar = tmp_path / "arbiter-rulings.json"
    sidecar.write_text(json.dumps({"old_format": "no_schema_version"}))
    rulings = [_make_ruling(idx=0, ruling="BLOCK")]
    finding_map = {0: _make_finding(idx=0)}
    with patch("subprocess.run", return_value=MagicMock(returncode=0, stdout="")):
        # Should NOT raise
        process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            artifacts_dir=str(tmp_path),
        )
    # New schema written
    data = json.loads(sidecar.read_text())
    assert data["schema_version"] == "1.0.0"


def test_arbiter_processor_sidecar_concurrent_writers_no_loss(tmp_path):
    """Two concurrent threads writing to the sidecar both produce valid output (lock serializes them).

    Without fcntl.LOCK_EX coordination, two parallel arbiter runs targeting the
    same artifacts_dir would race on the atomic temp+rename — one writer's
    content silently disappears. The pre-commit gate consumes this sidecar, so a
    lost ruling becomes a silent BLOCK bypass. This test verifies that with
    serialization, the resulting sidecar is always one writer's complete output
    — never a torn write or corrupted JSON.
    """
    import threading

    def writer_a():
        process_rulings(
            rulings=[_make_ruling(idx=0, ruling="BLOCK", rationale="writer A")],
            finding_map={0: _make_finding(idx=0, file="a.py")},
            cycle_num=1,
            commit_sha="sha_a",
            artifacts_dir=str(tmp_path),
        )

    def writer_b():
        process_rulings(
            rulings=[_make_ruling(idx=0, ruling="DROP", rationale="writer B")],
            finding_map={0: _make_finding(idx=0, file="b.py")},
            cycle_num=2,
            commit_sha="sha_b",
            artifacts_dir=str(tmp_path),
        )

    # Patch subprocess so the DROP path in writer_b doesn't fail.
    with patch("subprocess.run", return_value=MagicMock(returncode=0, stdout="")):
        t1 = threading.Thread(target=writer_a)
        t2 = threading.Thread(target=writer_b)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

    # Sidecar exists and contains valid JSON (no torn write).
    sidecar = tmp_path / "arbiter-rulings.json"
    assert sidecar.exists()
    data = json.loads(sidecar.read_text())
    assert data["schema_version"] == "1.0.0"
    # One writer's full content survived — the key invariant is no torn write.
    assert data["commit_sha"] in ("sha_a", "sha_b")


def test_process_rulings_skips_unknown_finding_index_without_collision(
    tmp_path, capsys
):
    """Bug da45 critical (PR #203 finding): rulings whose finding_index is
    not in finding_map MUST be skipped with a warning, not silently
    coerced into a dedup hash off the empty-dict fallback. The prior
    behavior used finding_map.get(finding_idx, {}) which would produce
    collision-prone hashes — multiple invalid rulings would dedup to the
    same empty-finding bucket and either be dropped (DEFER) or poison
    the defense store (DROP).
    """
    finding_map = {0: _make_finding(idx=0)}
    rulings = [
        _make_ruling(idx=99, ruling="BLOCK"),
        _make_ruling(idx=42, ruling="DEFER"),
        _make_ruling(idx=7, ruling="DROP"),
    ]
    with patch("subprocess.run", return_value=MagicMock(returncode=0, stdout="")):
        result = process_rulings(
            rulings=rulings,
            finding_map=finding_map,
            cycle_num=1,
            commit_sha="abc",
            pr_number=42,
            artifacts_dir=str(tmp_path),
        )

    captured = capsys.readouterr()
    assert "unknown finding_index" in captured.err
    # All three rulings should be recorded as skipped, not processed.
    skipped = result.get("skipped_invalid_index", [])
    assert len(skipped) == 3
    assert sorted(s["finding_index"] for s in skipped) == [7, 42, 99]
    assert {s["ruling_type"] for s in skipped} == {"BLOCK", "DEFER", "DROP"}
    # No side effects were emitted for the invalid rulings.
    assert result["block"] == []
    assert result["defer_ticket_ids"] == []
    assert result["drop_defense_records"] == []


# ── Bug da45 PR #203 finding f-XXX — _finding_hash_for_dedup fallback path ────


def test_finding_hash_for_dedup_falls_back_to_cited_lines_when_file_absent():
    """When a finding lacks file/line_range but has cited_lines='path:range',
    _finding_hash_for_dedup must parse cited_lines into file+line_range so
    the dedup hash is stable across input shapes.

    PR #203 finding f-XXX: this fallback path was never exercised by tests
    (all test findings used the _make_finding helper which always populates
    file + line_range). A future change that mis-parses cited_lines would
    cause silent dedup collisions on real findings that lack file fields.
    """
    from dso_ci_review.arbiter_processor import _finding_hash_for_dedup

    # No file/line_range — must fall back to cited_lines parsing
    finding_via_cited = {
        "cited_lines": ["src/x.py:10-20"],
        "category": "correctness",
    }
    # Equivalent finding with file/line_range populated
    finding_explicit = {
        "file": "src/x.py",
        "line_range": "10-20",
        "category": "correctness",
    }
    h_cited = _finding_hash_for_dedup(finding_via_cited)
    h_explicit = _finding_hash_for_dedup(finding_explicit)
    assert h_cited == h_explicit, (
        f"cited_lines fallback produced different hash than explicit fields. "
        f"cited={h_cited}, explicit={h_explicit}"
    )


def test_finding_hash_for_dedup_uses_filename_only_when_no_colon_in_cited_lines():
    """cited_lines without a colon (no line range) — file becomes the whole
    cited_lines[0], line_range stays empty.
    """
    from dso_ci_review.arbiter_processor import _finding_hash_for_dedup

    finding = {"cited_lines": ["README.md"], "category": "maintainability"}
    h_cited = _finding_hash_for_dedup(finding)
    equiv = {"file": "README.md", "line_range": "", "category": "maintainability"}
    h_equiv = _finding_hash_for_dedup(equiv)
    assert h_cited == h_equiv


# ── Bug da45 PR #203 finding f-XXX — _create_defer_ticket race-loser ──────────


def test_create_defer_ticket_self_deletes_on_race_loss(tmp_path):
    """_create_defer_ticket creates a ticket, then re-queries; if a DIFFERENT
    ticket with the same Finding-Hash + Scope marker already exists, it
    must self-delete the just-created ticket and return the race-winner's ID.

    PR #203 finding f-XXX: this AC-amendment race-loser logic was untested.
    """
    from dso_ci_review.arbiter_processor import _create_defer_ticket

    ruling = {"ruling": "DEFER", "rationale": "test deferral"}
    finding = {"file": "x.py", "line_range": "1", "category": "correctness"}
    finding_hash = "h_test123"
    scope = "#42"
    winner_id = "task-EXISTING-WINNER"
    our_id = "task-OUR-LOSER"

    call_log = []

    def mock_run(cmd, **kwargs):
        call_log.append(list(cmd))
        m = MagicMock()
        m.returncode = 0
        if "create" in cmd:
            m.stdout = our_id
        elif "list" in cmd:
            # Race-winner already exists for this marker
            m.stdout = json.dumps(
                [
                    {
                        "ticket_id": winner_id,
                        "description": f"Finding-Hash: {finding_hash} Scope: {scope}",
                        "status": "open",
                    }
                ]
            )
        elif "delete" in cmd:
            m.stdout = "deleted"
        return m

    with patch("subprocess.run", side_effect=mock_run):
        result = _create_defer_ticket(
            ruling,
            finding,
            finding_hash,
            scope,
            cycle_num=1,
            ticket_cmd_path=".claude/scripts/dso",
        )

    # Should return the race-winner ID, not our_id
    assert result == winner_id, (
        f"Expected race-loser to return winner_id={winner_id!r}; got {result!r}"
    )
    # Must have called: create, list (re-query), delete (self-delete)
    cmds = [c[1:3] for c in call_log if len(c) >= 3]
    assert ["ticket", "create"] in cmds, "Should have created the loser ticket"
    assert ["ticket", "delete"] in cmds, "Should have self-deleted on race loss"
