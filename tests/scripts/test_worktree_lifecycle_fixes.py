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
    """worktree-create.sh auto-cleanup trigger must count only session worktrees."""

    def test_count_pattern_excludes_agent_worktrees(self) -> None:
        """Bug d5c1: line counting `worktree-` matches agent-* paths too.

        Mimics the count logic in worktree-create.sh against a synthetic
        `git worktree list` output containing both session worktrees and agent-*
        worktrees. The fixed pattern must match session worktrees only.
        """
        sample = "\n".join(
            [
                "/repo  abc [main]",
                "/repo/worktrees/worktree-20260525-082437  def [worktree-20260525-082437]",
                "/repo/worktrees/worktree-20260524-135547  ghi [worktree-20260524-135547]",
                "/repo/.claude/worktrees/agent-acdd4cdaf9be4045e  jkl [worktree-agent-acdd4cdaf9be4045e] locked",
                "/repo/.claude/worktrees/agent-ab24bca38e3324876  mno [worktree-agent-ab24bca38e3324876] locked",
            ]
        )
        # Extract the count line from the actual script
        content = CREATE_SCRIPT.read_text()
        m = re.search(
            r"WORKTREE_COUNT=\$\(git worktree list[^)]*\| (grep[^)]+)\)", content
        )
        assert m is not None, "WORKTREE_COUNT line not found in worktree-create.sh"
        grep_cmd = m.group(1).strip()
        # Run the grep against the synthetic sample, mimicking the script
        result = subprocess.run(
            ["bash", "-c", f"echo '{sample}' | {grep_cmd}"],
            capture_output=True,
            text=True,
            check=False,
        )
        count = int(result.stdout.strip() or "0")
        # 2 session worktrees + 2 agent-* worktrees in the sample.
        # The fix narrows the match so agent-* is excluded — count should be 2, not 4.
        assert count == 2, (
            f"Expected session-only count of 2, got {count}. "
            "agent-* worktrees should be excluded from the >=10 auto-cleanup trigger."
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
