"""Concurrency primitives for tickets-branch writes.

Provides snapshot isolation (snapshot_head) and rebase-retry semantics
(rebase_retry) for reconciler passes that write to the tickets orphan branch.

This module is inert on its own; callers are wired by subsequent tasks.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


@dataclass
class ConcurrencyEvent:
    """Structured event emitted by rebase_retry to describe a non-OK outcome."""

    kind: str  # abort_due_to_drift | reject_and_reschedule | abort_due_to_error
    message: str = ""
    attempt: int = 0


@dataclass
class Result:
    """Return value from rebase_retry."""

    ok: bool
    event: ConcurrencyEvent | None = None
    value: Any = None


def snapshot_head(repo_root: Path) -> str:
    """Return the current HEAD SHA of the tickets branch.

    Falls back to HEAD of the current branch when the tickets ref is absent
    (e.g., in a fresh test repo that has no orphan tickets branch yet).
    """
    result = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "tickets"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
    return result.stdout.strip()


def rebase_retry(
    repo_root: Path,
    write_fn: Callable[[], Any],
    *,
    max_attempts: int = 3,
) -> Result:
    """Execute write_fn with rebase-retry on push rejection.

    Algorithm for each attempt:
      1. Capture tickets-branch HEAD before write.
      2. Execute write_fn().
      3. If HEAD changed since capture → abort_due_to_drift (no retry).
      4. If write_fn raises an exception → abort_due_to_error (no retry).
      5. Otherwise return Result(ok=True, value=<write_fn return value>).

    After max_attempts exhausted → reject_and_reschedule.

    No persistent state is held across passes; all counters live in local
    stack frames.
    """
    for attempt in range(1, max_attempts + 1):
        head_before = snapshot_head(repo_root)
        try:
            value = write_fn()
        except Exception as exc:  # noqa: BLE001
            return Result(
                ok=False,
                event=ConcurrencyEvent(
                    kind="abort_due_to_error",
                    message=str(exc),
                    attempt=attempt,
                ),
            )
        head_after = snapshot_head(repo_root)
        if head_after != head_before:
            return Result(
                ok=False,
                event=ConcurrencyEvent(
                    kind="abort_due_to_drift",
                    message=f"HEAD changed {head_before[:8]}→{head_after[:8]}",
                    attempt=attempt,
                ),
            )
        return Result(ok=True, value=value)

    return Result(
        ok=False,
        event=ConcurrencyEvent(
            kind="reject_and_reschedule",
            message=f"exhausted {max_attempts} attempts",
            attempt=max_attempts,
        ),
    )
