from __future__ import annotations

import json
import os
import tempfile
import time
from pathlib import Path

_24H_NS = 24 * 3600 * 1_000_000_000


def _store_dir(repo_root: Path) -> Path:
    return repo_root / "bridge_state" / "bridge_alerts"


def _today_file(repo_root: Path) -> Path:
    from datetime import datetime, timezone

    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return _store_dir(repo_root) / f"{date_str}.jsonl"


def append(record: dict, repo_root: Path) -> None:
    """Append a record to today's JSONL alert log."""
    store_dir = _store_dir(repo_root)
    store_dir.mkdir(parents=True, exist_ok=True)
    today = _today_file(repo_root)
    with today.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def is_deduped(key: str, repo_root: Path, window_ns: int = _24H_NS) -> bool:
    """Return True if an unresolved alert with this key was written within the window."""
    store_dir = _store_dir(repo_root)
    if not store_dir.is_dir():
        return False
    now = time.time_ns()
    for jf in sorted(store_dir.glob("*.jsonl")):
        try:
            for line in jf.read_text(encoding="utf-8").splitlines():
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("key") == key and not rec.get("resolved"):
                    ts = rec.get("timestamp_ns", 0)
                    if now - ts <= window_ns:
                        return True
        except Exception:
            continue
    return False


def _atomic_write(path: Path, content: str) -> None:
    """Replace `path` atomically with `content`.

    Writes via tempfile + fsync + os.replace so a crash mid-write cannot leave
    the destination truncated or partially written — the prior `write_text`
    approach truncated first and could lose the whole file on SIGKILL/OOM.
    """
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_str = tempfile.mkstemp(dir=str(parent), prefix=f".{path.name}.tmp.")
    tmp_path = Path(tmp_str)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
        tmp_path = None  # type: ignore[assignment]
    finally:
        if tmp_path is not None and tmp_path.exists():
            tmp_path.unlink()


def patch_bug_filed(key: str, bug_ticket_id: str, repo_root: Path) -> None:
    """Patch the latest unresolved record for key with bug_ticket_id.

    The rewrite is atomic (tempfile + os.replace + fsync) so a crash mid-write
    cannot lose the day's alert history. Non-dict JSONL payloads (e.g. a bare
    number from a corrupt writer) are preserved verbatim rather than crashing
    the patch attempt — the inner guard checks isinstance(rec, dict) before
    accessing rec.get().
    """
    store_dir = _store_dir(repo_root)
    if not store_dir.is_dir():
        return
    for jf in sorted(store_dir.glob("*.jsonl"), reverse=True):
        lines = []
        patched = False
        try:
            for line in jf.read_text(encoding="utf-8").splitlines():
                rec = None
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    pass  # malformed JSONL line — skip and preserve original text
                if (
                    not patched
                    and isinstance(rec, dict)
                    and rec.get("key") == key
                    and not rec.get("resolved")
                ):
                    rec["bug_ticket_id"] = bug_ticket_id
                    rec["op"] = "bug_filed"
                    patched = True
                lines.append(json.dumps(rec) if isinstance(rec, dict) else line)
            if patched:
                _atomic_write(jf, "\n".join(lines) + "\n")
                return
        except Exception:
            continue
