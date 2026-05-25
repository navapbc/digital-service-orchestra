"""Advisory lock primitives for the reconciler — tickets-branch pass-lock + phase-gate.

Provides:
  ReconcileLockError  — raised on fail-CLOSED conditions (missing branch, unknown errors)
  check_pass_lock     — returns True/False; raises ReconcileLockError on fail-CLOSED
  acquire_pass_lock   — write lock file to tickets branch via rebase_retry
  release_pass_lock   — delete lock file from tickets branch via rebase_retry
                        (ownership check: mismatch → warn + no-op, no exception)
  check_phase_gate    — returns True if advancement is blocked by gate file

All tickets-branch writes MUST go through rebase_retry from _concurrency.py
(plan-review F3: do not invent new write paths).
"""

from __future__ import annotations

import importlib.util
import logging
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Module-level logger
# ---------------------------------------------------------------------------

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Lazy import of _concurrency to respect the importlib.util loading convention
# ---------------------------------------------------------------------------

_CONCURRENCY_PATH = Path(__file__).parent / "_concurrency.py"


def _load_concurrency():
    """Load _concurrency module, caching in sys.modules."""
    key = "dso_reconciler__concurrency_advisory"
    if key in sys.modules:
        return sys.modules[key]
    spec = importlib.util.spec_from_file_location(key, _CONCURRENCY_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[key] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _rebase_retry(repo_root: Path, write_fn, **kwargs):
    """Thin wrapper so tests can monkeypatch advisory_lock._rebase_retry."""
    concurrency = _load_concurrency()
    return concurrency.rebase_retry(repo_root, write_fn, **kwargs)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_LOCK_FILE = ".reconciler-pass-lock"
_GATE_FILE = ".reconciler-phase-gate"


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class ReconcileLockError(RuntimeError):
    """Raised on fail-CLOSED conditions in the advisory lock subsystem.

    Fail-CLOSED means: when we cannot determine lock state confidently (e.g.
    missing tickets branch, unrecognised git error), we block the orchestrator
    rather than silently disabling concurrency protection.
    """


# ---------------------------------------------------------------------------
# git show helper with stderr discrimination (AC amendment G4)
# ---------------------------------------------------------------------------


def _git_show_tickets_file(repo_root: Path, filename: str) -> str | None:
    """Read *filename* from the tickets branch using ``git show``.

    Returns:
        str  — file contents if the file exists on the tickets branch.
        None — if the file is absent on tickets branch (normal, not an error).

    Raises:
        ReconcileLockError — if the tickets branch itself is missing, or if an
            unrecognised non-zero exit occurs (fail-CLOSED discipline).

    Stderr discrimination (G4):
        - exit 0                       → return stdout (file present)
        - exit != 0, 'unknown revision' in stderr  → tickets branch missing → raise
        - exit != 0, 'does not exist in' in stderr → file absent on branch  → None
        - exit != 0, anything else                 → unrecognised error     → raise
    """
    result = subprocess.run(
        ["git", "-C", str(repo_root), "show", f"tickets:{filename}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return result.stdout

    stderr = result.stderr or ""

    if "unknown revision" in stderr or "unknown ref" in stderr:
        raise ReconcileLockError(
            f"tickets branch not found in {repo_root}: {stderr.strip()!r} — "
            "cannot determine lock state (fail-CLOSED)"
        )

    if "does not exist in" in stderr or "exists on disk, but not in" in stderr:
        # File is absent on the tickets branch — normal no-lock state
        return None

    # Unrecognised error — fail-CLOSED
    raise ReconcileLockError(
        f"git show tickets:{filename} returned exit {result.returncode} with "
        f"unrecognised stderr: {stderr.strip()!r} (fail-CLOSED)"
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def check_pass_lock(repo_root: Path) -> bool:
    """Return True if .reconciler-pass-lock is present on the tickets branch.

    Returns False when the lock file is absent (normal — no active lock).

    Raises:
        ReconcileLockError — if the tickets branch is missing or an unrecognised
            git error occurs (fail-CLOSED).
    """
    contents = _git_show_tickets_file(repo_root, _LOCK_FILE)
    return contents is not None


def acquire_pass_lock(pass_id: str, repo_root: Path) -> None:
    """Write .reconciler-pass-lock to the tickets branch via rebase_retry.

    The lock file contains *pass_id* + timestamp_ns on separate lines so that
    release_pass_lock can verify ownership before deletion.

    Uses rebase_retry from _concurrency.py (plan-review F3 alignment: existing
    serialization-safe write path; no new raw git commit path introduced).

    Raises:
        ReconcileLockError — if rebase_retry fails (drift exhaustion or error).
    """
    timestamp_ns = time.time_ns()
    lock_contents = f"{pass_id}\n{timestamp_ns}\n"

    def _write():
        _write_file_to_tickets_branch(
            repo_root, _LOCK_FILE, lock_contents, f"acquire lock pass_id={pass_id}"
        )

    result = _rebase_retry(repo_root, _write)
    if not result.ok:
        raise ReconcileLockError(
            f"acquire_pass_lock failed for pass_id={pass_id!r}: "
            f"{result.event.kind if result.event else 'unknown'}: "
            f"{result.event.message if result.event else ''}"
        )


def release_pass_lock(pass_id: str, repo_root: Path) -> None:
    """Delete .reconciler-pass-lock from the tickets branch via rebase_retry.

    Ownership check (G5): reads the existing lock contents and verifies the
    stored pass_id matches *pass_id* before deletion. On mismatch, logs a
    warning and returns without raising (defensive — never disrupt the caller,
    never unlock another process's lock).

    Idempotent: if the lock file is absent, returns silently.

    Raises:
        ReconcileLockError — if the tickets branch is missing.
    """
    # Ownership check before attempting deletion
    try:
        contents = _git_show_tickets_file(repo_root, _LOCK_FILE)
    except ReconcileLockError:
        raise

    if contents is None:
        # Already absent — idempotent success
        return

    # Parse pass_id from first line
    stored_pass_id = contents.splitlines()[0].strip() if contents else ""
    if stored_pass_id != pass_id:
        logger.warning(
            "release_pass_lock: pass_id mismatch — stored owner %r does not match "
            "caller %r; leaving lock in place (defensive owner-check)",
            stored_pass_id,
            pass_id,
        )
        return

    def _delete():
        _delete_file_from_tickets_branch(
            repo_root, _LOCK_FILE, f"release lock pass_id={pass_id}"
        )

    result = _rebase_retry(repo_root, _delete)
    if not result.ok:
        raise ReconcileLockError(
            f"release_pass_lock failed for pass_id={pass_id!r}: "
            f"{result.event.kind if result.event else 'unknown'}: "
            f"{result.event.message if result.event else ''}"
        )


def check_phase_gate(target_mode, repo_root: Path) -> bool:
    """Return True if *target_mode* is blocked by the phase gate on tickets branch.

    The gate file (.reconciler-phase-gate) contains the MODE name at or below
    which advancement is permitted. If *target_mode* has a strictly higher rank
    than the gated mode, the gate blocks advancement.

    Gate semantics (rank-based):
        blocked iff target_mode.rank() > gated_mode.rank()

    Returns False (not blocked) when:
        - The gate file is absent on the tickets branch.
        - target_mode.rank() <= gated_mode.rank() (within permitted range).

    Example:
        Gate file contains 'bootstrap-strict' (rank 1).
        BOOTSTRAP_THROTTLE (rank 2) → blocked (2 > 1) → True.
        BOOTSTRAP_STRICT (rank 1)   → not blocked (1 == 1) → False.

    The Mode enum and its rank() method are imported from mode.py at call time
    so this module does not hard-code ordering.
    """
    try:
        contents = _git_show_tickets_file(repo_root, _GATE_FILE)
    except ReconcileLockError:
        # Missing tickets branch — treat as no gate (don't block)
        return False

    if contents is None:
        # Gate file absent — no block
        return False

    gated_mode_str = contents.strip()
    if not gated_mode_str:
        return False

    # Import Mode from mode.py via path to avoid circular-import issues
    mode_path = Path(__file__).parent / "mode.py"
    mode_key = "dso_reconciler_mode_phase_gate"
    if mode_key not in sys.modules:
        spec = importlib.util.spec_from_file_location(mode_key, mode_path)
        assert spec is not None and spec.loader is not None
        mod = importlib.util.module_from_spec(spec)
        sys.modules[mode_key] = mod
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
    mode_mod = sys.modules[mode_key]

    try:
        gated_mode = mode_mod.Mode.from_str(gated_mode_str)
    except ValueError:
        logger.warning(
            "check_phase_gate: unrecognised mode %r in gate file; treating as no gate",
            gated_mode_str,
        )
        return False

    return target_mode.rank() > gated_mode.rank()


# ---------------------------------------------------------------------------
# Low-level tickets-branch file write/delete helpers
# ---------------------------------------------------------------------------


def _write_file_to_tickets_branch(
    repo_root: Path, filename: str, contents: str, commit_message: str
) -> None:
    """Write *contents* to *filename* on the tickets orphan branch.

    Uses a temporary git worktree for the tickets branch so the main working
    tree branch pointer never changes.  This keeps rebase_retry's drift guard
    honest: only commits by *other* passes advance the tickets HEAD between our
    before/after snapshots.

    If the file already contains *contents* (idempotent retry path), the write
    is skipped and no commit is made — leaving HEAD unchanged so rebase_retry
    can detect no-drift and return ok=True on the retry pass.
    """
    import shutil as _shutil
    import tempfile as _tempfile

    # git worktree add requires the target dir to not exist
    worktree_parent = Path(_tempfile.mkdtemp(prefix="advisory-lock-wt-parent-"))
    worktree_dir = worktree_parent / "wt"
    try:
        _git_run(repo_root, ["worktree", "add", str(worktree_dir), "tickets"])
        file_path = worktree_dir / filename
        file_path.write_text(contents)
        _git_run_in(worktree_dir, ["add", filename])
        # Only commit if there are staged changes (idempotent guard for retries
        # where the same contents were already committed on a previous attempt)
        status = subprocess.run(
            ["git", "diff", "--cached", "--quiet"],
            capture_output=True,
            check=False,
            cwd=str(worktree_dir),
        )
        if status.returncode != 0:
            # Non-zero means there ARE staged changes — commit them
            _git_run_in(worktree_dir, ["commit", "-m", commit_message])
    finally:
        try:
            _git_run(repo_root, ["worktree", "remove", "--force", str(worktree_dir)])
        except subprocess.CalledProcessError:
            # Best-effort cleanup: if the worktree remove fails (e.g. already gone),
            # ignore it — rmtree below will still clean up the temp directory.
            pass
        _shutil.rmtree(worktree_parent, ignore_errors=True)


def _delete_file_from_tickets_branch(
    repo_root: Path, filename: str, commit_message: str
) -> None:
    """Delete *filename* from the tickets orphan branch.

    Uses a temporary git worktree so the main branch pointer is unchanged.
    Idempotent: if the file is absent, does nothing.
    """
    import shutil as _shutil
    import tempfile as _tempfile

    worktree_parent = Path(_tempfile.mkdtemp(prefix="advisory-lock-wt-parent-"))
    worktree_dir = worktree_parent / "wt"
    try:
        _git_run(repo_root, ["worktree", "add", str(worktree_dir), "tickets"])
        file_path = worktree_dir / filename
        if file_path.exists():
            _git_run_in(worktree_dir, ["rm", "-f", filename])
            _git_run_in(worktree_dir, ["commit", "-m", commit_message])
    finally:
        try:
            _git_run(repo_root, ["worktree", "remove", "--force", str(worktree_dir)])
        except subprocess.CalledProcessError:
            # Best-effort cleanup: if the worktree remove fails (e.g. already gone),
            # ignore it — rmtree below will still clean up the temp directory.
            pass
        _shutil.rmtree(worktree_parent, ignore_errors=True)


def _current_branch(repo_root: Path) -> str:
    """Return the current branch name, or empty string on detached HEAD / failure."""
    result = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return ""


def _git_run(repo_root: Path, args: list[str]) -> subprocess.CompletedProcess:
    """Run a git command in repo_root; raise CalledProcessError on non-zero exit."""
    return subprocess.run(
        ["git", "-C", str(repo_root)] + args,
        capture_output=True,
        text=True,
        check=True,
    )


def _git_run_in(directory: Path, args: list[str]) -> subprocess.CompletedProcess:
    """Run a git command with CWD set to *directory* (for temporary worktrees)."""
    return subprocess.run(
        ["git"] + args,
        capture_output=True,
        text=True,
        check=True,
        cwd=str(directory),
    )
