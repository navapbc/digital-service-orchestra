"""dso_ci_review.local_workflow — Local (non-CI) review workflow orchestrator.

Entry point for /dso:commit local review gate. Manages cycle ledger in
filesystem-only mode. Ledger init reads from the local filesystem only;
PR reconstruction is a CI-only code path not used here.

Public API:
    _init_local_ledger(artifacts_dir, branch_name, commit_sha) -> dict
        Returns {"cycle_num": int, "ledger": dict}

    main() -> int
        CLI entry point; propagates exit code from review dispatch.
"""

from __future__ import annotations

import copy
import fcntl
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from dso_ci_review import cycle_ledger


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


def main() -> int:
    """CLI entry point for the local review workflow.

    Reads WORKFLOW_PLUGIN_ARTIFACTS_DIR from environment (defaults to /tmp).
    Resolves current HEAD commit SHA via git.

    Returns exit code (0 = success).
    """
    artifacts_dir = os.environ.get("WORKFLOW_PLUGIN_ARTIFACTS_DIR", "/tmp")

    try:
        current_commit_sha = (
            subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip()
        )
    except subprocess.CalledProcessError as e:
        print(
            f"ERROR: git rev-parse HEAD failed (exit {e.returncode})",
            file=sys.stderr,
        )
        return 1

    try:
        branch_name = (
            subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"])
            .decode()
            .strip()
        )
    except subprocess.CalledProcessError:
        branch_name = "unknown"

    result = _init_local_ledger(
        artifacts_dir=artifacts_dir,
        branch_name=branch_name,
        commit_sha=current_commit_sha,
    )

    print(
        f"Local review workflow: cycle_num={result['cycle_num']} "
        f"branch={branch_name} sha={current_commit_sha[:12]}",
        file=sys.stderr,
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
