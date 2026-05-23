#!/usr/bin/env python3
"""append_review_cycle.py — Atomic append-only writer for the cycles[] array.

Appends a single entry to the `cycles` array of a remediation review artifact
JSON file. Uses fcntl.flock + tempfile + os.replace for safe concurrent writes.

Entry fields (exactly 5):
  n               — cycle number (int)
  draft_hash      — SHA-256 of the reviewed diff (str)
  findings_count  — number of findings reported (int)
  verdict         — pass | fail | escalate
  timestamp_iso   — RFC 3339 timestamp (str)

Usage:
  python3 append_review_cycle.py \\
      --artifact <path> \\
      --n <int> \\
      --draft-hash <sha256> \\
      --findings-count <int> \\
      --verdict <pass|fail|escalate> \\
      [--timestamp-iso <rfc3339>]
"""

import argparse
import fcntl
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Atomically append a review cycle entry to a remediation artifact."
    )
    parser.add_argument(
        "--artifact", required=True, help="Path to the artifact JSON file."
    )
    parser.add_argument("--n", type=int, required=True, help="Cycle number (int).")
    parser.add_argument(
        "--draft-hash", required=True, help="SHA-256 of the reviewed diff."
    )
    parser.add_argument(
        "--findings-count", type=int, required=True, help="Number of findings reported."
    )
    parser.add_argument(
        "--verdict",
        required=True,
        choices=["pass", "fail", "escalate"],
        help="Cycle verdict: pass | fail | escalate.",
    )
    parser.add_argument(
        "--timestamp-iso",
        default=None,
        help="RFC 3339 timestamp. Defaults to current UTC time.",
    )
    return parser.parse_args()


def _default_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def append_cycle(
    artifact_path: str,
    n: int,
    draft_hash: str,
    findings_count: int,
    verdict: str,
    timestamp_iso: str,
) -> None:
    """Read-modify-write artifact JSON, appending one cycle entry atomically."""
    artifact = Path(artifact_path)
    if not artifact.exists():
        print(f"error: artifact not found: {artifact_path}", file=sys.stderr)
        sys.exit(1)

    lock_path = artifact.parent / (artifact.name + ".lock")

    with open(lock_path, "a") as lock_fh:
        fcntl.flock(lock_fh, fcntl.LOCK_EX)
        try:
            raw = artifact.read_text(encoding="utf-8")
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError as exc:
                print(f"error: invalid JSON in artifact: {exc}", file=sys.stderr)
                sys.exit(1)

            if not isinstance(obj, dict):
                print("error: artifact root must be a JSON object", file=sys.stderr)
                sys.exit(1)

            obj.setdefault("cycles", [])

            entry = {
                "n": n,
                "draft_hash": draft_hash,
                "findings_count": findings_count,
                "verdict": verdict,
                "timestamp_iso": timestamp_iso,
            }
            obj["cycles"].append(entry)

            # Atomic write: write to a sibling temp file, then os.replace.
            dir_ = str(artifact.parent)
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=dir_,
                delete=False,
                suffix=".tmp",
            ) as tmp_fh:
                tmp_name = tmp_fh.name
                json.dump(obj, tmp_fh, indent=2)
                tmp_fh.write("\n")

            os.replace(tmp_name, artifact_path)
        finally:
            fcntl.flock(lock_fh, fcntl.LOCK_UN)


def main() -> None:
    args = _parse_args()
    timestamp = (
        args.timestamp_iso if args.timestamp_iso is not None else _default_timestamp()
    )
    append_cycle(
        artifact_path=args.artifact,
        n=args.n,
        draft_hash=args.draft_hash,
        findings_count=args.findings_count,
        verdict=args.verdict,
        timestamp_iso=timestamp,
    )


if __name__ == "__main__":
    main()
