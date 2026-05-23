"""Shared attestation helpers for dso_reconciler band modules.

Provides verify_attested_commit() which checks that a commit is GPG-signed
and that its committer is a human (not a bot in the allowlist).
"""

from __future__ import annotations

import subprocess


def verify_attested_commit(sha: str, allowlist: list[str]) -> bool:
    """Return True when *sha* is human-attested.

    A commit is considered human-attested when ALL of the following hold:

    1. ``git verify-commit <sha>`` exits 0 (valid GPG signature).
    2. The committer email is NOT in *allowlist* (bot emails are excluded
       because automated commits do not count as human review).

    Returns False on any subprocess error so callers can treat failures as
    "not attested" without crashing.

    Args:
        sha: Full or abbreviated commit SHA to verify.
        allowlist: List of bot committer email addresses to exclude.

    Returns:
        True if the commit passes both checks, False otherwise.
    """
    try:
        result = subprocess.run(
            ["git", "verify-commit", sha],
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            return False
    except Exception:  # noqa: BLE001
        return False

    try:
        email_result = subprocess.run(
            ["git", "log", "-1", "--format=%ae", sha],
            capture_output=True,
            text=True,
            check=False,
        )
        if email_result.returncode != 0:
            return False
        committer_email = email_result.stdout.strip()
    except Exception:  # noqa: BLE001
        return False

    if committer_email in allowlist:
        return False

    return True
