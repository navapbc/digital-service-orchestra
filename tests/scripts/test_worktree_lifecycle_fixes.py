"""Behavioral tests for d5c1 (under-cleanup) and 907d (over-cleanup) worktree fixes.

d5c1 defects (tested by execution):
  - `has_stashes()` in worktree-cleanup.sh must scope to the worktree's branch,
    not return true whenever any stash exists in the repo.
  - `worktree-create.sh` auto-cleanup trigger must count only session worktrees
    (worktree-YYYYMMDD-HHMMSS) toward its >=10 threshold, not agent-* worktrees.

907d defenses (tested structurally per behavioral testing standard rule 5):
  - per-worktree-review-commit.md must declare a post-return worktree-existence
    check section before any `cd $WORKTREE_PATH` operation.
  - single-agent-integrate.md must declare the same.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
CLEANUP_SCRIPT = REPO_ROOT / "plugins" / "dso" / "scripts" / "worktree-cleanup.sh"
CREATE_SCRIPT = REPO_ROOT / "plugins" / "dso" / "scripts" / "worktree-create.sh"
PER_WORKTREE_RC = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "sprint"
    / "prompts"
    / "per-worktree-review-commit.md"
)
SINGLE_AGENT_INT = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "shared"
    / "prompts"
    / "single-agent-integrate.md"
)


def _git(cwd: Path, *args: str) -> str:
    out = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return out.stdout


@pytest.fixture
def repo_with_two_worktrees(tmp_path: Path) -> tuple[Path, Path, Path]:
    """Create a git repo with two worktrees on distinct branches and one stash on one branch."""
    main = tmp_path / "main"
    main.mkdir()
    _git(main, "init", "-q", "-b", "main")
    _git(main, "config", "user.email", "t@t")
    _git(main, "config", "user.name", "t")
    (main / "README").write_text("init\n")
    _git(main, "add", "README")
    _git(main, "commit", "-q", "-m", "init")

    # Worktree A on branch "feature-a"
    wt_a = tmp_path / "wt_a"
    _git(main, "worktree", "add", "-b", "feature-a", str(wt_a))

    # Worktree B on branch "agent-b" (simulating an agent-* worktree)
    wt_b = tmp_path / "wt_b"
    _git(main, "worktree", "add", "-b", "agent-b", str(wt_b))

    # Stash something on feature-a only
    (wt_a / "scratch").write_text("scratch\n")
    _git(wt_a, "add", "scratch")
    _git(wt_a, "stash", "push", "-m", "stash on feature-a")

    return main, wt_a, wt_b


def _source_and_call_has_stashes(wt_path: Path) -> int:
    """Source worktree-cleanup.sh's has_stashes function and call it.

    Sourcing the whole script with set -e would exit on parse errors; instead
    we extract the has_stashes function definition and source just that.
    """
    content = CLEANUP_SCRIPT.read_text()
    # Extract has_stashes() function body — looks for "has_stashes() {" through matching "}"
    match = re.search(r"(has_stashes\(\)\s*\{.*?\n\})", content, re.DOTALL)
    assert match is not None, "has_stashes() function not found in worktree-cleanup.sh"
    fn_def = match.group(1)
    harness = f"""
set -u
{fn_def}
if has_stashes "{wt_path}"; then
    echo "HAS_STASHES"
    exit 0
else
    echo "NO_STASHES"
    exit 0
fi
"""
    result = subprocess.run(
        ["bash", "-c", harness], capture_output=True, text=True, check=False
    )
    if "HAS_STASHES" in result.stdout:
        return 1
    if "NO_STASHES" in result.stdout:
        return 0
    raise AssertionError(
        f"unexpected output: {result.stdout!r} stderr={result.stderr!r}"
    )


@pytest.mark.scripts
class TestD5c1HasStashesPerWorktree:
    """has_stashes() must be scoped to the worktree's branch, not repo-wide."""

    def test_has_stashes_returns_false_for_worktree_with_no_stash_on_its_branch(
        self, repo_with_two_worktrees: tuple[Path, Path, Path]
    ) -> None:
        """Bug d5c1: stashes are repo-scoped but applied as per-worktree veto.

        Setup: repo with two worktrees, a stash exists on feature-a only.
        Expected: has_stashes(wt_b on agent-b) returns false because no stash references agent-b.
        RED (current behavior): has_stashes returns true for wt_b because `git stash list`
        returns the same list from any worktree.
        GREEN (after fix): has_stashes filters by the worktree's branch.
        """
        _, wt_a, wt_b = repo_with_two_worktrees
        # Pre-condition check: a stash actually exists in the repo
        stash_list = _git(wt_b, "stash", "list")
        assert "feature-a" in stash_list, f"setup invariant failed: {stash_list!r}"

        # Behavior under test: wt_b's branch (agent-b) has no stash → should return false
        result = _source_and_call_has_stashes(wt_b)
        assert result == 0, (
            "has_stashes(wt_b) should return false: agent-b has no stash, "
            "but a stash exists on feature-a in the same repo."
        )

    def test_has_stashes_returns_true_for_worktree_with_stash_on_its_branch(
        self, repo_with_two_worktrees: tuple[Path, Path, Path]
    ) -> None:
        """Positive case: worktree whose branch DOES have a stash should report true."""
        _, wt_a, _ = repo_with_two_worktrees
        result = _source_and_call_has_stashes(wt_a)
        assert result == 1, (
            "has_stashes(wt_a) should return true: feature-a has a stash."
        )


@pytest.mark.scripts
class TestD5c1WorktreeCreateCount:
    """worktree-create.sh auto-cleanup trigger must count only session worktrees.

    Behavioral test: build a real git repo with a known mix of session-named
    and agent-* worktrees, then invoke `worktree-create.sh` in that repo and
    observe whether the auto-cleanup trigger fires (it prints
    "Running automatic cleanup..." to stderr when activated). We verify the
    OBSERVABLE behavior — not the regex pattern — so the test survives any
    equivalent refactor of the count discriminator.
    """

    def test_agent_worktrees_do_not_trigger_auto_cleanup(self, tmp_path: Path) -> None:
        """Bug d5c1: pre-fix, `grep -c "worktree-"` matched agent-* worktree
        paths and branches, so 11 agent-* worktrees would fire the >=10 trigger
        even with zero session worktrees. Post-fix, only session worktrees
        (worktree-YYYYMMDD-HHMMSS) count toward the threshold.

        Setup: a real git repo with 2 session worktrees and 9 agent-* worktrees
        (11 total — would have triggered pre-fix). Post-fix, session count is 2,
        below the >=10 threshold, so cleanup must NOT trigger.
        """
        repo = tmp_path / "repo"
        repo.mkdir()
        _git(repo, "init", "-q", "-b", "main")
        _git(repo, "config", "user.email", "t@t")
        _git(repo, "config", "user.name", "t")
        (repo / "README").write_text("init\n")
        _git(repo, "add", "README")
        _git(repo, "commit", "-q", "-m", "init")

        # 2 session worktrees — use realistic worktree-YYYYMMDD-HHMMSS names.
        for i, ts in enumerate(("20260520-100000", "20260521-100000")):
            _git(
                repo, "worktree", "add", "-b", f"worktree-{ts}", str(tmp_path / f"s{i}")
            )
        # 9 agent-* worktrees — branch names mirror real harness output.
        for i in range(9):
            _git(
                repo,
                "worktree",
                "add",
                "-b",
                f"worktree-agent-{i:016x}",
                str(tmp_path / f"a{i}"),
            )

        total = len(_git(repo, "worktree", "list").splitlines())
        assert total == 12, (
            f"setup invariant: expected 12 worktrees (main+2+9), got {total}"
        )

        # Invoke worktree-create.sh in this repo; we only care about whether the
        # >=10 trigger fires. Use a name that the script can accept; the call
        # may fail later for unrelated reasons (no origin remote, etc.) — we
        # capture stderr and inspect for the trigger marker either way.
        env = os.environ.copy()
        env["CLAUDE_PLUGIN_ROOT"] = str(REPO_ROOT / "plugins" / "dso")
        env["WORKTREE_DIR_OVERRIDE"] = str(tmp_path / "new")
        result = subprocess.run(
            ["bash", str(CREATE_SCRIPT), "--name=probe-new", "--skip-pull"],
            cwd=str(repo),
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        # The observable signal: the script prints "Running automatic cleanup..."
        # to stderr when WORKTREE_COUNT >= 10.
        assert "Running automatic cleanup" not in result.stderr, (
            "auto-cleanup must NOT trigger when only agent-* worktrees push the "
            "raw count over 10 — session-named worktrees alone (count=2) are below "
            "the threshold.\nstderr was:\n" + result.stderr
        )

    def test_ten_session_worktrees_do_trigger_auto_cleanup(
        self, tmp_path: Path
    ) -> None:
        """Positive control: confirms the count discriminator is reachable in the
        test environment and that the trigger DOES fire at the threshold.

        Without this control, the negative test above could pass spuriously if
        the script exited early on an unrelated condition (missing remote, etc.)
        before reaching the count block. Setting up 10 session worktrees and
        observing the trigger message proves the count check executes.
        """
        repo = tmp_path / "repo"
        repo.mkdir()
        _git(repo, "init", "-q", "-b", "main")
        _git(repo, "config", "user.email", "t@t")
        _git(repo, "config", "user.name", "t")
        (repo / "README").write_text("init\n")
        _git(repo, "add", "README")
        _git(repo, "commit", "-q", "-m", "init")

        for i in range(10):
            _git(
                repo,
                "worktree",
                "add",
                "-b",
                f"worktree-2026052{i}-100000",
                str(tmp_path / f"s{i}"),
            )

        env = os.environ.copy()
        env["CLAUDE_PLUGIN_ROOT"] = str(REPO_ROOT / "plugins" / "dso")
        env["WORKTREE_DIR_OVERRIDE"] = str(tmp_path / "new")
        result = subprocess.run(
            ["bash", str(CREATE_SCRIPT), "--name=probe-new", "--skip-pull"],
            cwd=str(repo),
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        assert "Running automatic cleanup" in result.stderr, (
            "positive control: with 10 session worktrees, auto-cleanup MUST fire.\n"
            "If this assertion fails, the count block is unreachable in the test "
            "environment and the negative test above is also untrustworthy.\n"
            "stderr was:\n" + result.stderr
        )


@pytest.mark.skills
class Test907dPostReturnExistenceCheck:
    """Skill files must declare a post-return worktree existence check (907d defense)."""

    def test_per_worktree_review_commit_declares_post_return_check(self) -> None:
        """per-worktree-review-commit.md must have a heading/section announcing the
        post-sub-agent-return worktree existence verification before any cd into
        the worktree path. Structural test only (per CLAUDE.md behavioral testing
        standard rule 5: instruction files are tested by their structural boundary,
        not content strings).
        """
        content = PER_WORKTREE_RC.read_text()
        # The structural boundary is a heading-shaped marker introducing the check.
        # We assert a section heading containing '907d' (the bug ID) exists — this
        # is a structural anchor that survives refactoring of the surrounding prose.
        assert re.search(
            r"^(#{1,4}|\*\*).*907d.*post.return.*existence",
            content,
            re.IGNORECASE | re.MULTILINE,
        ), (
            "per-worktree-review-commit.md must declare a structural section for the "
            "907d post-return existence check (heading or bold-introduced step)."
        )

    def test_single_agent_integrate_declares_post_return_check(self) -> None:
        """single-agent-integrate.md must declare the same defense."""
        content = SINGLE_AGENT_INT.read_text()
        assert re.search(
            r"^(#{1,4}|\*\*).*907d.*post.return.*existence",
            content,
            re.IGNORECASE | re.MULTILINE,
        ), (
            "single-agent-integrate.md must declare a structural section for the "
            "907d post-return existence check (heading or bold-introduced step)."
        )
