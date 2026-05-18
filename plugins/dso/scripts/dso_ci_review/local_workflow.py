"""dso_ci_review.local_workflow — Local (non-CI) review workflow orchestrator.

Entry point for /dso:commit local review gate. Manages cycle ledger in
filesystem-only mode. Ledger init reads from the local filesystem only;
PR reconstruction is a CI-only code path not used here.

Public API:
    _init_local_ledger(artifacts_dir, branch_name, commit_sha) -> dict
        Returns {"cycle_num": int, "ledger": dict}

    main(artifacts_dir=None, commit_sha=None, diff_text="", max_cycles=None) -> int
        CLI entry point; propagates exit code from review dispatch.
        When called without arguments, reads from environment + git.
"""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from dso_ci_review import cycle_dispatcher
from dso_ci_review import cycle_ledger
from dso_ci_review import stability
from dso_ci_review._config import read_config_int


def _ledger_path(artifacts_dir: str) -> str:
    """Return the canonical cycle-ledger.json path for the given artifacts dir."""
    return str(Path(artifacts_dir) / "cycle-ledger.json")


def _lock_file_path(artifacts_dir: str) -> str:
    """Return the lock file path co-located with the ledger."""
    return str(Path(artifacts_dir) / "cycle-ledger.lock")


def _init_local_ledger(
    artifacts_dir: str,
    branch_name: str,
    commit_sha: str,
) -> dict:
    """Initialize cycle ledger for a local (non-CI) review run.

    Read the existing ledger from filesystem, determine the next cycle number,
    and return the result. Reads ledger from filesystem only; the PR
    reconstruction code path is CI-only and is not invoked here.

    Concurrent-init safety: acquires fcntl LOCK_EX for the read-decide window
    to prevent two concurrent processes from receiving the same cycle_num.

    Args:
        artifacts_dir: Directory containing cycle-ledger.json (and lock file).
        branch_name: Current branch name (informational; not used in logic).
        commit_sha: Current HEAD commit SHA for SHA-aware reset semantics.

    Returns:
        dict with keys:
            - "cycle_num": int — the cycle number to use for this run.
            - "ledger": dict — the current ledger (before this cycle is appended).

    Semantics:
        - No ledger / empty cycles: cycle_num=1 (fresh start).
        - Last cycle SHA != commit_sha: cycle_num=1 (SHA change reset).
        - Last cycle SHA == commit_sha: cycle_num = last_cycle_num + 1.
    """
    # Ensure artifacts dir exists so lock file can be created there.
    Path(artifacts_dir).mkdir(parents=True, exist_ok=True)

    lock_path = _lock_file_path(artifacts_dir)
    ledger_path_str = _ledger_path(artifacts_dir)

    # Open (or create) the lock file atomically using O_CREAT | O_RDWR.
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        lock_file = os.fdopen(lock_fd, "r")
    except Exception:
        try:
            os.close(lock_fd)
        except OSError:
            pass
        raise

    try:
        # Acquire exclusive lock for the read-decide window.
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            ledger = cycle_ledger.read_ledger(ledger_path_str)
            cycles = ledger.get("cycles", [])

            if not cycles:
                # Fresh start: no prior cycles.
                cycle_num = 1
            else:
                last_cycle = cycles[-1]
                last_sha = last_cycle.get("commit_sha", "")
                if last_sha != commit_sha:
                    # SHA changed — reset counter for new commit.
                    cycle_num = 1
                else:
                    # Same SHA — continue from where we left off.
                    cycle_num = last_cycle["cycle_num"] + 1

            # Write a placeholder entry to reserve cycle_num before releasing
            # the lock. This prevents concurrent callers from reading an empty
            # (or stale) ledger and computing the same cycle_num.
            # NOTE: cannot call write_ledger() here — it acquires the same lock
            # and would deadlock. Write directly using atomic rename instead.
            #
            # Build the updated ledger as a NEW dict (do not mutate the object
            # returned by read_ledger — callers may hold a reference to it).
            placeholder = {
                "cycle_num": cycle_num,
                "timestamp_utc": None,
                "commit_sha": commit_sha,
                "findings": [],
                "findings_hash": "",
                "halt_reason": None,
                "_placeholder": True,
            }
            updated_ledger = {
                **ledger,
                "cycles": list(ledger.get("cycles", [])) + [placeholder],
            }
            ledger_p = Path(ledger_path_str)
            ledger_p.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(
                prefix=ledger_p.name + ".", dir=str(ledger_p.parent)
            )
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(json.dumps(updated_ledger, indent=2))
                os.replace(tmp_path, ledger_path_str)
            except Exception:
                if Path(tmp_path).exists():
                    os.unlink(tmp_path)
                raise

            return {"cycle_num": cycle_num, "ledger": ledger}
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    finally:
        lock_file.close()


def _dispatch_local_reviewer(
    diff_text: str,
    cycle_num: int,
    prior_defenses: list,
) -> list[dict]:
    """Dispatch a local reviewer for the given diff and cycle.

    In the local workflow, dispatches via dispatch_review() without posting
    PR comments (pr_number=None). Returns the findings list from the result.

    Args:
        diff_text: Unified diff text to review.
        cycle_num: Current review cycle number (informational).
        prior_defenses: Prior defenses from previous cycles (for re-review).

    Returns:
        List of finding dicts.
    """
    from dso_ci_review.dispatch import dispatch_review  # noqa: PLC0415

    result = dispatch_review(
        diff_text=diff_text,
        provider_chain=["anthropic"],
    )
    return result.get("findings", [])


def _invoke_arbiter_hook(
    artifacts_dir: str,
    commit_sha: str,
) -> int:
    """Invoke the arbiter hook when max review cycles are exhausted.

    Returns exit code: non-zero indicates a blocking ruling.
    Full arbiter implementation is in a later task; this stub returns 1
    to indicate review cycle exhaustion requires human attention.

    Args:
        artifacts_dir: Directory containing review artifacts.
        commit_sha: Current HEAD commit SHA.

    Returns:
        Exit code (0 = pass, non-zero = block).
    """
    print(
        f"ARBITER: max review cycles exhausted for commit {commit_sha[:12]}",
        file=sys.stderr,
    )
    return 1


def main(
    artifacts_dir: str | None = None,
    commit_sha: str | None = None,
    diff_text: str = "",
    max_cycles: int | None = None,
) -> int:
    """CLI entry point for the local review workflow.

    When called without arguments, reads configuration from the environment
    and resolves git state. When called with explicit arguments (e.g., from
    tests), uses those values directly.

    Args:
        artifacts_dir: Directory for review artifacts. Defaults to
            WORKFLOW_PLUGIN_ARTIFACTS_DIR env var or /tmp.
        commit_sha: Current HEAD commit SHA. Defaults to git rev-parse HEAD.
        diff_text: Unified diff text to review. Defaults to empty string
            (real implementation reads git diff in later task).
        max_cycles: Maximum review cycles. Defaults to review.max_cycles
            config value (default 4).

    Returns exit code (0 = pass, non-zero = block/error).
    """
    # Resolve artifacts_dir
    if artifacts_dir is None:
        artifacts_dir = os.environ.get("WORKFLOW_PLUGIN_ARTIFACTS_DIR", "/tmp")

    # Resolve max_cycles from config when not explicitly provided
    if max_cycles is None:
        max_cycles = read_config_int("review.max_cycles", default=4)

    # Resolve commit_sha from git when not explicitly provided
    if commit_sha is None:
        try:
            commit_sha = (
                subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip()
            )
        except subprocess.CalledProcessError as e:
            print(
                f"ERROR: git rev-parse HEAD failed (exit {e.returncode})",
                file=sys.stderr,
            )
            return 1

    # Resolve branch name (informational; not used in dispatch logic)
    try:
        branch_name = (
            subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"])
            .decode()
            .strip()
        )
    except subprocess.CalledProcessError:
        branch_name = "unknown"

    # Initialize ledger and determine starting cycle_num
    result = _init_local_ledger(
        artifacts_dir=artifacts_dir,
        branch_name=branch_name,
        commit_sha=commit_sha,
    )
    ledger = result["ledger"]
    cycle_num = result["cycle_num"]
    ledger_path = os.path.join(artifacts_dir, "cycle-ledger.json")

    print(
        f"Local review workflow: cycle_num={cycle_num} "
        f"branch={branch_name} sha={commit_sha[:12]}",
        file=sys.stderr,
    )

    # Pre-loop SHORT_CIRCUIT check: if a prior arbiter ruling exists for this
    # commit, skip re-running the review loop entirely.
    action_result = cycle_dispatcher.next_action(
        ledger, max_cycles, [], commit_sha, artifacts_dir
    )
    if action_result.get("action") == "SHORT_CIRCUIT":
        rulings_path = os.path.join(artifacts_dir, "arbiter-rulings.json")
        try:
            with open(rulings_path) as f:
                rulings = json.load(f)
        except (OSError, json.JSONDecodeError):
            rulings = []
        has_block = any(
            r.get("ruling") == "BLOCK"
            for r in (rulings if isinstance(rulings, list) else [])
        )
        return 1 if has_block else 0

    # Multi-cycle review loop (reviewer-first ordering).
    # Each iteration: dispatch reviewer → compute hash → append to ledger
    # → ask dispatcher for next action.
    prior_defenses: list = []
    while True:
        findings = _dispatch_local_reviewer(diff_text, cycle_num, prior_defenses)

        # Compute stable finding identity hash from (file, line_range, category).
        tuples = [
            (
                f.get("file", ""),
                str(f.get("line_range", "")),
                f.get("category", ""),
            )
            for f in findings
        ]
        findings_hash = stability.finding_hash(
            {
                "file": "|".join(t[0] for t in sorted(tuples)),
                "line_range": "|".join(t[1] for t in sorted(tuples)),
                "category": "|".join(t[2] for t in sorted(tuples)),
            }
        )

        # Atomically append this cycle's data to the on-disk ledger.
        cycle_ledger.append_cycle(
            ledger_path, cycle_num, tuples, commit_sha, findings_hash
        )

        # Also update in-memory ledger so next_action sees current state.
        ledger.setdefault("cycles", []).append(
            {
                "cycle_num": cycle_num,
                "commit_sha": commit_sha,
                "findings": tuples,
                "findings_hash": findings_hash,
            }
        )

        # Ask the dispatcher what to do next.
        action_result = cycle_dispatcher.next_action(
            ledger, max_cycles, findings, commit_sha, artifacts_dir
        )
        action = action_result.get("action")

        if action == "PASS":
            return 0

        if action == "DISPATCH_ARBITER":
            return _invoke_arbiter_hook(artifacts_dir, commit_sha)

        if action == "SHORT_CIRCUIT":
            # SHORT_CIRCUIT mid-loop: treat as pass (arbiter already ruled PASS).
            return 0

        # DISPATCH_NEXT: advance cycle counter and continue loop.
        # The cycle_num in the action result reflects the current cycle;
        # increment by 1 to get the next cycle number.
        cycle_num = cycle_num + 1


if __name__ == "__main__":
    sys.exit(main())
