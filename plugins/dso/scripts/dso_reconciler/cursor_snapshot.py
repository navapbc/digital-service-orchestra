#!/usr/bin/env python3
"""Cursor snapshot step: captures outbound and inbound cursors to bridge_state/cursor-snapshot.json."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class StepResult:
    name: str
    ok: bool
    message: str
    details: dict = field(default_factory=dict)


def run(repo_root: Path | None = None) -> StepResult:
    """Capture cursors from tickets branch and commit snapshot."""
    if repo_root is None:
        repo_root = Path(__file__).parents[4]  # project root

    snapshot_path = repo_root / "bridge_state" / "cursor-snapshot.json"

    try:
        # Step 1: Resolve tickets-branch HEAD SHA
        result = subprocess.run(
            ["git", "rev-parse", "tickets"],
            capture_output=True,
            text=True,
            cwd=str(repo_root),
            check=False,
        )
        if result.returncode != 0:
            return StepResult(
                name="cursor_snapshot",
                ok=False,
                message=f"could not resolve tickets branch: {result.stderr.strip()}",
            )
        head_sha = result.stdout.strip()

        # Step 2: Idempotence check
        if snapshot_path.exists():
            try:
                existing = json.loads(snapshot_path.read_text())
                if existing.get("head_sha") == head_sha:
                    return StepResult(
                        name="cursor_snapshot",
                        ok=True,
                        message="snapshot already current (idempotent)",
                        details={"skipped": True, "head_sha": head_sha},
                    )
            except Exception:
                pass  # corrupt snapshot — overwrite it

        # Step 3: Read .outbound-checkpoint.json from tickets branch
        outbound = None
        cp_result = subprocess.run(
            ["git", "show", "tickets:.outbound-checkpoint.json"],
            capture_output=True,
            text=True,
            cwd=str(repo_root),
            check=False,
        )
        if cp_result.returncode == 0:
            try:
                outbound = json.loads(cp_result.stdout)
            except json.JSONDecodeError:
                outbound = None

        # Step 4: Read bridge_state/inbound-cursor.json
        inbound = None
        inbound_path = repo_root / "bridge_state" / "inbound-cursor.json"
        if inbound_path.exists():
            try:
                inbound = json.loads(inbound_path.read_text())
            except json.JSONDecodeError:
                inbound = None

        # Step 5: Build snapshot
        snapshot = {
            "head_sha": head_sha,
            "outbound_checkpoint": outbound,
            "inbound_cursor": inbound,
        }

        # Step 6: Atomic write via tempfile
        snapshot_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = None
        try:
            fd, tmp_path_str = tempfile.mkstemp(
                dir=str(snapshot_path.parent),
                prefix=".cursor-snapshot-tmp.",
            )
            tmp_path = Path(tmp_path_str)
            with os.fdopen(fd, "w") as f:
                json.dump(snapshot, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.rename(tmp_path, snapshot_path)
            tmp_path = None
        finally:
            if tmp_path and tmp_path.exists():
                tmp_path.unlink()

        # Step 7: Commit to tickets orphan branch via git
        git_add = subprocess.run(
            ["git", "add", str(snapshot_path)],
            capture_output=True,
            text=True,
            cwd=str(repo_root),
            check=False,
        )
        if git_add.returncode != 0:
            return StepResult(
                name="cursor_snapshot",
                ok=False,
                message=f"git add failed: {git_add.stderr.strip()}",
            )

        git_commit = subprocess.run(
            [
                "git",
                "commit",
                "-m",
                f"chore: cursor snapshot at tickets HEAD {head_sha[:8]}",
                "--allow-empty-message",
            ],
            capture_output=True,
            text=True,
            cwd=str(repo_root),
            check=False,
        )
        # "nothing to commit" is ok (idempotent)
        if git_commit.returncode != 0 and "nothing to commit" not in git_commit.stdout:
            return StepResult(
                name="cursor_snapshot",
                ok=False,
                message=f"git commit failed: {git_commit.stderr.strip()}",
            )

        return StepResult(
            name="cursor_snapshot",
            ok=True,
            message=f"cursor snapshot committed at tickets HEAD {head_sha[:8]}",
            details={"head_sha": head_sha, "outbound": outbound, "inbound": inbound},
        )

    except Exception as exc:
        return StepResult(
            name="cursor_snapshot",
            ok=False,
            message=f"unexpected error: {exc}",
        )
