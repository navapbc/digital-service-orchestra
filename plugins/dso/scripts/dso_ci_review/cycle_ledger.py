"""dso_ci_review.cycle_ledger — Python reader/writer for cycle-ledger.json.

Coordinates with write-cycle-ledger.sh via the same lock file
($ARTIFACTS_DIR/cycle-ledger.lock) and the same v1.1.0 schema documented in
${CLAUDE_PLUGIN_ROOT}/docs/contracts/cycle-ledger.md.

Public functions:
    read_ledger(path)              — load ledger; empty v1.1.0 schema if absent
    write_ledger(path, ledger)     — atomic write with cross-process lock
    append_cycle(path, ...)        — read-modify-write under lock; append cycle entry
    reconstruct_from_pr_comments(pr_number, repo) — rebuild ledger from PR comments
    _resolve_artifacts_dir()       — mirrors shell get_artifacts_dir() semantics
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


# Marker grammar — must match the format documented in cycle-ledger.md
#
# v1.1.0 marker example:
#   DSO-Review-Cycle: 1 commit_sha=abc123 findings_hash=h1 tuples=[["x.py","1","c"]]
#
# We capture up to end-of-string for tuples= because the JSON value may contain
# bracket nesting; a non-greedy /\[.*?\]/ would stop at the first inner ']'.
_MARKER_RE_V11 = re.compile(
    r"DSO-Review-Cycle:\s+(\S+)\s+commit_sha=(\S+)\s+findings_hash=(\S+)\s+tuples=(\[.*\])\s*$"
)
_MARKER_RE_LEGACY = re.compile(r"DSO-Review-Cycle:\s+(\S+)(?:\s+findings-hash=(\S+))?")


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
    return {"schema_version": "1.1.0", "epic_id": "", "cycles": []}


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
        return os.fdopen(fd, "r")
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
) -> None:
    """Read-modify-write under lock; append a cycle entry to the ledger.

    The lock path is exactly ``<dir>/cycle-ledger.lock`` (sibling of the
    ledger file) so that this writer coordinates with write-cycle-ledger.sh.
    """
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
                "commit_sha": commit_sha,
                "findings": findings_tuples,
                "findings_hash": findings_hash,
                "halt_reason": halt_reason,
            }
            ledger.setdefault("cycles", []).append(new_entry)
            _atomic_write(path, json.dumps(ledger, indent=2))
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def reconstruct_from_pr_comments(pr_number: int, repo: str) -> dict:
    """Rebuild ledger from PR comments containing DSO-Review-Cycle markers.

    Handles both v1.1.0 markers (with commit_sha + tuples) and legacy v1.0.0
    markers (findings-hash only). Malformed entries are skipped with a stderr
    warning and the top-level ``reconstruction_gaps`` flag is set to True.
    """
    cmd = ["gh", "api", f"repos/{repo}/pulls/{pr_number}/comments", "--paginate"]
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
    seen_cycles: set[int] = set()

    for comment in comments:
        body = comment.get("body", "")
        for raw_line in body.split("\n"):
            line = raw_line.strip()
            if not line.startswith("DSO-Review-Cycle:"):
                continue
            # Try v1.1.0 format first
            m_v11 = _MARKER_RE_V11.search(line)
            if m_v11:
                try:
                    cycle_num = int(m_v11.group(1))
                except ValueError:
                    print(
                        f"WARNING: malformed v1.1.0 marker (non-int cycle_num), "
                        f"skipping: {line!r}",
                        file=sys.stderr,
                    )
                    has_gaps = True
                    continue
                commit_sha = m_v11.group(2)
                findings_hash = m_v11.group(3)
                try:
                    tuples = json.loads(m_v11.group(4))
                except json.JSONDecodeError:
                    print(
                        f"WARNING: malformed v1.1.0 marker (bad tuples JSON), "
                        f"skipping: {line!r}",
                        file=sys.stderr,
                    )
                    has_gaps = True
                    continue
                if cycle_num in seen_cycles:
                    continue
                seen_cycles.add(cycle_num)
                ledger["cycles"].append(
                    {
                        "cycle_num": cycle_num,
                        "commit_sha": commit_sha,
                        "findings": tuples,
                        "findings_hash": findings_hash,
                        "halt_reason": None,
                    }
                )
                continue

            # Fall back to legacy v1.0.0 format
            m_legacy = _MARKER_RE_LEGACY.search(line)
            if m_legacy:
                try:
                    cycle_num = int(m_legacy.group(1))
                except ValueError:
                    print(
                        f"WARNING: malformed legacy marker (non-int cycle_num), "
                        f"skipping: {line!r}",
                        file=sys.stderr,
                    )
                    has_gaps = True
                    continue
                findings_hash = m_legacy.group(2) or ""
                if cycle_num in seen_cycles:
                    continue
                seen_cycles.add(cycle_num)
                ledger["cycles"].append(
                    {
                        "cycle_num": cycle_num,
                        "commit_sha": "",
                        "findings": [],
                        "findings_hash": findings_hash,
                        "halt_reason": None,
                    }
                )
                continue

            # No grammar matched — count as gap and warn
            print(
                f"WARNING: unrecognized DSO-Review-Cycle marker, skipping: {line!r}",
                file=sys.stderr,
            )
            has_gaps = True

    if has_gaps:
        ledger["reconstruction_gaps"] = True

    # Stable ordering
    ledger["cycles"].sort(key=lambda c: c["cycle_num"])
    return ledger
