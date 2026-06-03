"""dso_ci_review.cycle_ledger — Python reader/writer for cycle-ledger.json.

Coordinates with write-cycle-ledger.sh via the same lock file
($ARTIFACTS_DIR/cycle-ledger.lock) and the same v1.2.0 schema documented in
${CLAUDE_PLUGIN_ROOT}/docs/contracts/cycle-ledger.md.

Public functions:
    read_ledger(path)              — load ledger; empty v1.2.0 schema if absent
    write_ledger(path, ledger)     — atomic write with cross-process lock
    append_cycle(path, ...)        — read-modify-write under lock; append cycle entry
    reconstruct_from_pr_comments(pr_number, repo) — rebuild ledger from PR comments
    _resolve_artifacts_dir()       — mirrors shell get_artifacts_dir() semantics

## Backward-Compatibility

The reader tolerates BOTH v1.1.0 (sha-only) and v1.2.0 (pr+sha) marker
formats. v1.1.0 entries are returned with pr_number=_SENTINEL_PR_NUMBER (0).
A v1.1.0 entry matches any pr_number filter until a v1.2.0 entry is written
for that specific pr_number on the same sha, at which point the v1.2.0 entry
supersedes for that (pr_number, sha) tuple. Writer emits v1.2.0 only.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from dso_ci_review.cycle_marker_format import (
    SENTINEL_PR_NUMBER as _SENTINEL_PR_NUMBER_FROM_FMT,
    cycle_marker_list_endpoint,
    parse_cycle_marker,
)


# Sentinel pr_number for legacy v1.1.0 entries lacking explicit pr_number.
# Reading: a v1.1.0 entry is materialized into the in-memory ledger with
# pr_number=_SENTINEL_PR_NUMBER, which matches any pr_number filter until
# the next review cycle on that PR writes a v1.2.0 entry that supersedes it.
# Writing: append_cycle MUST NEVER write _SENTINEL_PR_NUMBER for new cycles.
#
# Re-exported from cycle_marker_format (single source of truth post bug 9788).
_SENTINEL_PR_NUMBER = _SENTINEL_PR_NUMBER_FROM_FMT

# Marker grammar lives in dso_ci_review.cycle_marker_format (single source
# of truth post bug 9788). This module dispatches via parse_cycle_marker()
# and switches on the returned schema_version field rather than maintaining
# its own regexes.


def _resolve_artifacts_dir() -> str:
    """Mirror shell get_artifacts_dir() semantics.

    Resolution order:
      1. WORKFLOW_PLUGIN_ARTIFACTS_DIR env var (if set)
      2. /tmp/workflow-plugin-<16-char-hash-of-REPO_ROOT>/
      3. Legacy /tmp/lockpick-test-artifacts-<worktree-name>/ — migrated once if new path is empty
    """
    override = os.environ.get("WORKFLOW_PLUGIN_ARTIFACTS_DIR", "").strip()
    if override:
        Path(override).mkdir(parents=True, exist_ok=True)
        return override

    try:
        repo_root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        repo_root = os.getcwd()

    repo_hash = hashlib.sha256(repo_root.encode("utf-8")).hexdigest()[:16]
    new_path = f"/tmp/workflow-plugin-{repo_hash}"
    Path(new_path).mkdir(parents=True, exist_ok=True)

    # One-time legacy migration: when new path is empty, copy from
    # /tmp/lockpick-test-artifacts-<worktree-name>/
    if not any(Path(new_path).iterdir()):
        worktree_name = Path(repo_root).name
        legacy = Path(f"/tmp/lockpick-test-artifacts-{worktree_name}")
        if legacy.exists() and legacy.is_dir():
            for item in legacy.iterdir():
                dest = Path(new_path) / item.name
                try:
                    if item.is_dir():
                        shutil.copytree(item, dest, dirs_exist_ok=True)
                    else:
                        shutil.copy2(item, dest)
                except OSError:
                    # Best-effort migration — never raise on legacy copy failure
                    pass
    return new_path


def _empty_ledger() -> dict:
    return {"schema_version": "1.2.0", "epic_id": "", "cycles": []}


def read_ledger(path: str) -> dict:
    """Load ledger; return empty v1.1.0 schema if file absent.

    On corrupt or unreadable JSON, returns the empty schema rather than
    raising — callers may log separately.
    """
    p = Path(path)
    if not p.exists():
        return _empty_ledger()
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return _empty_ledger()


def _lock_path(ledger_path: str) -> str:
    """Lock file co-located with ledger, named cycle-ledger.lock.

    Matches the shell writer's lock convention so the two coordinate via
    fcntl.LOCK_EX on the same inode.
    """
    p = Path(ledger_path)
    return str(p.parent / "cycle-ledger.lock")


def _atomic_write(path: str, data: str) -> None:
    """Write to a sibling temp file then rename for atomicity."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=p.name + ".", dir=str(p.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.replace(tmp_path, str(p))
    except Exception:
        if Path(tmp_path).exists():
            os.unlink(tmp_path)
        raise


def _open_lock(lock_path: str):
    """Race-free open of the lock file (bug da45 PR #202 finding f-c3d4e5f6).

    Path.touch() + open() in two steps has a TOCTOU window: a concurrent
    process could delete the lock file between the touch and the open,
    causing FileNotFoundError on the open call and crashing the writer
    with a partial-state ledger.

    os.open(O_CREAT | O_RDWR) creates-and-opens atomically; even if the
    file is unlinked by another process AFTER our open(), our file
    descriptor remains valid (POSIX semantics: open file descriptors
    keep the inode alive until close()).
    """
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        # If os.fdopen raises (resource exhaustion), close the raw fd we
        # just allocated so it doesn't leak (bug da45 PR #202 cycle-N
        # finding f-XXX). The raised exception still propagates.
        return os.fdopen(fd, "r", encoding="utf-8")
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass  # best-effort cleanup
        raise


def write_ledger(path: str, ledger: dict) -> None:
    """Atomic write coordinated via cycle-ledger.lock (fcntl.LOCK_EX)."""
    lock_path = _lock_path(path)
    Path(lock_path).parent.mkdir(parents=True, exist_ok=True)
    with _open_lock(lock_path) as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            _atomic_write(path, json.dumps(ledger, indent=2))
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def append_cycle(
    path: str,
    cycle_num: int,
    findings_tuples: list,
    commit_sha: str,
    findings_hash: str,
    halt_reason: str | None = None,
    pr_number: int = _SENTINEL_PR_NUMBER,
) -> None:
    """Read-modify-write under lock; append a cycle entry to the ledger.

    The lock path is exactly ``<dir>/cycle-ledger.lock`` (sibling of the
    ledger file) so that this writer coordinates with write-cycle-ledger.sh.

    Args:
        pr_number: The PR number for this cycle entry. Must not be
            _SENTINEL_PR_NUMBER (0) — sentinel is reserved for backward-
            compatible reads of legacy v1.1.0 entries and must never be
            written as a new cycle.

    Raises:
        ValueError: If pr_number == _SENTINEL_PR_NUMBER (defensive guard
            against accidental sentinel-write).
    """
    if pr_number == _SENTINEL_PR_NUMBER:
        raise ValueError(
            f"append_cycle: pr_number must not be {_SENTINEL_PR_NUMBER} "
            f"(_SENTINEL_PR_NUMBER is reserved for legacy v1.1.0 reads, "
            f"never for new cycle writes)"
        )
    lock_path = _lock_path(path)
    Path(lock_path).parent.mkdir(parents=True, exist_ok=True)
    with _open_lock(lock_path) as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            ledger = read_ledger(path)
            new_entry = {
                "cycle_num": cycle_num,
                "timestamp_utc": datetime.now(timezone.utc).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"
                ),
                "pr_number": pr_number,
                "commit_sha": commit_sha,
                "findings": findings_tuples,
                "findings_hash": findings_hash,
                "halt_reason": halt_reason,
            }
            # Upsert: replace placeholder entry if one already exists for this
            # cycle_num (written by _init_local_ledger to reserve the slot),
            # otherwise append a new entry.
            cycles = ledger.setdefault("cycles", [])
            for i, entry in enumerate(cycles):
                if entry.get("cycle_num") == cycle_num:
                    cycles[i] = new_entry
                    break
            else:
                cycles.append(new_entry)
            _atomic_write(path, json.dumps(ledger, indent=2))
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def reconstruct_from_pr_comments(pr_number: int, repo: str) -> dict:
    """Rebuild ledger from PR comments containing DSO-Review-Cycle markers.

    Handles both v1.1.0 markers (with commit_sha + tuples) and legacy v1.0.0
    markers (findings-hash only). Malformed entries are skipped with a stderr
    warning and the top-level ``reconstruction_gaps`` flag is set to True.
    """
    cmd = [
        "gh",
        "api",
        cycle_marker_list_endpoint(repo, pr_number),
        "--paginate",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        comments = json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        # Bug da45 PR #202 finding f-e5f6g7h8 (fail-open error handling):
        # silently flagging reconstruction_gaps without surfacing why made
        # CI troubleshooting impossible. Emit a diagnostic stderr line per
        # failure class so operators can distinguish 'no prior cycles'
        # (legitimate empty result) from 'gh API failed' / 'gh missing'.
        print(
            f"WARNING: gh api failed for PR #{pr_number} (exit {e.returncode}); "
            f"reconstruction_gaps=true. stderr: "
            f"{(e.stderr or '').strip() or '(none)'}",
            file=sys.stderr,
        )
        ledger = _empty_ledger()
        ledger["reconstruction_gaps"] = True
        return ledger
    except FileNotFoundError:
        print(
            "WARNING: gh CLI is not installed; reconstruction_gaps=true. "
            "Install with `brew install gh` or see https://cli.github.com",
            file=sys.stderr,
        )
        ledger = _empty_ledger()
        ledger["reconstruction_gaps"] = True
        return ledger
    except json.JSONDecodeError as e:
        print(
            f"WARNING: gh api output is not valid JSON for PR #{pr_number}; "
            f"reconstruction_gaps=true. parse error: {e}",
            file=sys.stderr,
        )
        ledger = _empty_ledger()
        ledger["reconstruction_gaps"] = True
        return ledger

    ledger = _empty_ledger()
    has_gaps = False
    # Map from cycle_num to (entry_dict, is_v12). v1.2.0 entries supersede v1.1.0
    # entries for the same cycle_num (mixed-format deduplication: v1.2.0 wins).
    seen_cycles: dict[int, tuple[dict, bool]] = {}

    for comment in comments:
        body = comment.get("body", "")
        for raw_line in body.split("\n"):
            line = raw_line.strip()
            if not line.startswith("DSO-Review-Cycle:"):
                continue

            parsed = parse_cycle_marker(line)
            if parsed is None:
                # Either an unrecognized grammar OR a known grammar with a
                # malformed tuples JSON. Both count as gaps for reconstruction
                # confidence reporting.
                print(
                    f"WARNING: unrecognized or malformed DSO-Review-Cycle marker, "
                    f"skipping: {line!r}",
                    file=sys.stderr,
                )
                has_gaps = True
                continue

            cycle_num = parsed.cycle_num
            is_v12 = parsed.schema_version == "1.2.0"

            if parsed.schema_version == "1.0.0":
                # Legacy format: only add if no higher-version entry already
                # captured this cycle_num (legacy never supersedes).
                if cycle_num not in seen_cycles:
                    seen_cycles[cycle_num] = (
                        {
                            "cycle_num": cycle_num,
                            "commit_sha": "",
                            "findings": [],
                            "findings_hash": parsed.findings_hash,
                            "pr_number": _SENTINEL_PR_NUMBER,
                            "halt_reason": None,
                        },
                        False,
                    )
                continue

            if not is_v12:
                # v1.1.0: only added if no v1.2.0 entry already captured this
                # cycle_num (cycle-ledger.md:80 — Mixed-format dedup rule).
                existing = seen_cycles.get(cycle_num)
                if existing is not None and existing[1]:
                    continue

            entry = {
                "cycle_num": cycle_num,
                "pr_number": parsed.pr_number,
                "commit_sha": parsed.commit_sha,
                "findings": parsed.tuples,
                "findings_hash": parsed.findings_hash,
                "halt_reason": None,
            }
            seen_cycles[cycle_num] = (entry, is_v12)

    ledger["cycles"] = [entry for entry, _ in seen_cycles.values()]

    if has_gaps:
        ledger["reconstruction_gaps"] = True

    # Stable ordering
    ledger["cycles"].sort(key=lambda c: c["cycle_num"])
    return ledger


def _cli_main(argv: list[str] | None = None) -> int:
    """CLI entry point for the cycle_ledger module.

    Usage:
        python3 -m dso_ci_review.cycle_ledger reconstruct-from-pr <pr-number> <repo>

    Emits the reconstructed ledger as JSON on stdout. This is the single
    grammar/parser source that write-cycle-ledger.sh --reconstruct-from-pr
    delegates to, enforcing local-vs-CI parity per Step 4.75.
    """
    argv = list(sys.argv if argv is None else argv)
    if len(argv) >= 4 and argv[1] == "reconstruct-from-pr":
        try:
            pr_num = int(argv[2])
        except ValueError:
            print(
                f"error: <pr-number> must be an integer, got {argv[2]!r}",
                file=sys.stderr,
            )
            return 2
        repo = argv[3]
        ledger = reconstruct_from_pr_comments(pr_num, repo)
        print(json.dumps(ledger, indent=2))
        return 0
    print(
        "Usage: python3 -m dso_ci_review.cycle_ledger "
        "reconstruct-from-pr <pr-number> <repo>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(_cli_main(sys.argv))
