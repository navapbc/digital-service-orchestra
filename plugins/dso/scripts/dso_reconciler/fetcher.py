#!/usr/bin/env python3
"""Fetcher: pull a normalized Jira snapshot and write it to bridge_state/snapshots/.

fetch_snapshot(pass_id) calls AcliClient.search_issues() with a full-project JQL,
normalizes each issue into a {key: fields} dict with deterministic key ordering,
and writes the snapshot as sorted-key JSON to bridge_state/snapshots/<pass_id>.json.

Two fetches over identical remote data produce byte-identical files (idempotent).
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path


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


def fetch_snapshot(
    pass_id: str,
    repo_root: Path | None = None,
) -> Path:
    """Fetch all DIG project issues and write a normalized snapshot JSON.

    Calls AcliClient.search_issues("project = DIG"), normalizes each issue
    into a {key -> {fields sorted by key}} mapping, and writes the result as
    deterministically-ordered JSON to bridge_state/snapshots/<pass_id>.json.

    Args:
        pass_id: Identifier for this pass (used as the filename stem).
        repo_root: Repository root path. Defaults to 4 levels above this file
                   (dso_reconciler/ → scripts/ → dso/ → plugins/ → repo root).

    Returns:
        Path to the written snapshot file.

    Raises:
        Any exception raised by AcliClient.search_issues() propagates out.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    acli_mod = _load_acli()
    client = acli_mod.AcliClient(
        jira_url=os.environ.get("JIRA_URL", ""),
        user=os.environ.get("JIRA_USER", ""),
        api_token=os.environ.get("JIRA_API_TOKEN", ""),
    )

    issues = client.search_issues("project = DIG")

    # Normalize: build {key -> fields} with deterministic field ordering
    snapshot: dict[str, dict] = {}
    for issue in issues:
        key = issue.get("key", "")
        if not key:
            continue
        fields = issue.get("fields", {})
        if not isinstance(fields, dict):
            fields = {}
        # Sort field keys for determinism
        normalized_fields = {k: fields[k] for k in sorted(fields.keys())}
        snapshot[key] = normalized_fields

    # Write to bridge_state/snapshots/<pass_id>.json with deterministic ordering
    output_dir = repo_root / "bridge_state" / "snapshots"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{pass_id}.json"
    output_path.write_text(json.dumps(snapshot, sort_keys=True, indent=2))

    return output_path
