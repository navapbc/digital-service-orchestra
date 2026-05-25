#!/usr/bin/env python3
"""Fetcher: pull a normalized Jira snapshot and write it to bridge_state/snapshots/.

fetch_snapshot(pass_id) calls AcliClient.search_issues() with the filtered JQL,
paginates through the working set via ``_iter_pages``, dedups cross-page
duplicates while emitting an observable alert, enforces the 1000-issue ACLI
ceiling by raising ``SilentTruncationError``, and writes the normalized snapshot
as sorted-key JSON to bridge_state/snapshots/<pass_id>.json.

Two fetches over identical remote data produce byte-identical files (idempotent).
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path

# Filtered JQL — only unresolved issues or issues updated in the last hour.
# AC literal: `project = DIG AND (resolution = Unresolved OR updated >= -1h)`
JQL = "project = DIG AND (resolution = Unresolved OR updated >= -1h)"

# Hard ACLI ceiling per JRACLOUD-94632.
_ACLI_CEILING = 1000


class SilentTruncationError(Exception):
    """Raised when ACLI silently truncates the result set.

    Two trigger conditions:
      * Accumulated issue count reaches the 1000-issue ACLI ceiling.
      * ACLI returns the same ``next_page_token`` on two consecutive calls
        ("same-token-twice" cursor-stall mode).
    """

    def __init__(self, message: str = "", reason: str = "") -> None:
        super().__init__(message or reason or "silent truncation detected")
        self.reason = reason


def _load_acli():
    """Load acli-integration module via importlib."""
    acli_path = Path(__file__).parent.parent / "acli-integration.py"
    spec = importlib.util.spec_from_file_location("acli_integration", acli_path)
    if spec is None:
        raise FileNotFoundError(f"acli-integration.py not found at {acli_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("acli_integration", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _extract_issues(result) -> list[dict]:
    """Normalize a search_issues result to a list of issue dicts.

    ACLI stubs and the real client return either a bare list or a dict shaped
    ``{"issues": [...], "startAt": ..., "total": ...}``. Accept both.
    """
    if isinstance(result, dict):
        issues = result.get("issues", [])
        return list(issues) if isinstance(issues, list) else []
    if isinstance(result, list):
        return result
    return []


def _iter_pages(client, jql: str, page_size: int = 100):
    """Generator yielding one page (list[dict]) per ACLI call.

    Termination:
      * Page is empty or shorter than ``page_size`` (natural end).
      * Accumulated issue count would meet/exceed the 1000-issue ACLI ceiling
        — raises ``SilentTruncationError`` before yielding the violating page.
      * ACLI returns the same ``next_page_token`` on two consecutive calls
        ("same-token-twice") — raises ``SilentTruncationError(reason='same-token-twice')``.
    """
    start_at = 0
    accumulated = 0
    prev_token: object = None
    token_seen_count = 0
    while True:
        result = client.search_issues(jql, start_at=start_at, max_results=page_size)
        page = _extract_issues(result)

        # Same-token-twice cursor-stall detection. Inspect any of the common
        # token attribute names exposed by the client (POSIX-ish duck-typing).
        cur_token = None
        for attr in ("next_page_token", "nextPageToken"):
            if hasattr(client, attr):
                cur_token = getattr(client, attr)
                break
        if cur_token is not None and prev_token is not None and cur_token == prev_token:
            token_seen_count += 1
            if token_seen_count >= 1:
                raise SilentTruncationError(
                    "ACLI returned the same next_page_token twice in a row "
                    "(same-token-twice cursor stall)",
                    reason="same-token-twice",
                )
        else:
            token_seen_count = 0
        prev_token = cur_token

        if not page:
            return

        # 1000-issue ACLI ceiling: if adding this page would reach or exceed
        # the ceiling, raise rather than yield a silently-truncated set.
        if accumulated + len(page) >= _ACLI_CEILING:
            raise SilentTruncationError(
                f"ACLI working set reached the {_ACLI_CEILING}-issue ceiling "
                "(JRACLOUD-94632 silent truncation)",
                reason="ceiling",
            )

        yield page
        accumulated += len(page)

        if len(page) < page_size:
            return
        start_at += page_size


def collect(client, jql: str, page_size: int = 100) -> list[dict]:
    """Drain ``_iter_pages`` into a single flat list of issues."""
    issues: list[dict] = []
    for page in _iter_pages(client, jql, page_size=page_size):
        issues.extend(page)
    return issues


def fetch_snapshot(
    pass_id: str,
    repo_root: Path | None = None,
) -> Path:
    """Fetch all matching DIG issues and write a normalized snapshot JSON.

    Paginates via ``_iter_pages``, dedups cross-page key collisions (emitting
    a ``fetcher-dedup-suppressed`` alert via ``alert_store.append``), and
    writes a deterministically-ordered JSON snapshot to
    ``bridge_state/snapshots/<pass_id>.json``.

    Raises:
        SilentTruncationError: ACLI ceiling hit or same-token-twice stall.
        Any exception raised by ``AcliClient.search_issues()`` propagates out.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    acli_mod = _load_acli()
    client = acli_mod.AcliClient(
        jira_url=os.environ.get("JIRA_URL", ""),
        user=os.environ.get("JIRA_USER", ""),
        api_token=os.environ.get("JIRA_API_TOKEN", ""),
    )

    # Local import — avoid a circular at module load (alert_store is leaf).
    from plugins.dso.scripts.dso_reconciler import alert_store

    seen_keys: set[str] = set()
    snapshot: dict[str, dict] = {}

    for page in _iter_pages(client, JQL, page_size=100):
        for issue in page:
            key = issue.get("key", "")
            if not key:
                continue
            if key in seen_keys:
                # Cross-page duplicate — dedup AND emit observable alert.
                alert_store.append(
                    {
                        "kind": "fetcher-dedup-suppressed",
                        "key": key,
                        "pass_id": pass_id,
                    },
                    repo_root=repo_root,
                )
                continue
            seen_keys.add(key)
            fields = issue.get("fields", {})
            if not isinstance(fields, dict):
                fields = {}
            snapshot[key] = {k: fields[k] for k in sorted(fields.keys())}

    output_dir = repo_root / "bridge_state" / "snapshots"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{pass_id}.json"
    output_path.write_text(json.dumps(snapshot, sort_keys=True, indent=2))

    return output_path
