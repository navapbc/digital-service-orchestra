#!/usr/bin/env python3
"""Applier: dispatches mutations to AcliClient and writes per-pass flat-JSON manifest."""

from __future__ import annotations

import importlib.util
import json
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


def create_one(mutation: dict, client) -> dict:
    """Create a Jira issue from the mutation's fields. Returns the client result."""
    return client.create_issue(mutation.get("fields", {}))


def update_one(mutation: dict, client) -> dict:
    """Update an existing Jira issue. Returns the client result."""
    return client.update_issue(mutation.get("key"), mutation.get("fields", {}))


def delete_one(mutation: dict, client) -> None:
    """Close a Jira issue by transitioning it to 'Closed'."""
    client.transition_issue(mutation.get("key"), "Closed")


def apply(
    mutations: list[dict],
    pass_id: str,
    repo_root: Path | None = None,
) -> Path:
    """Dispatch mutations to AcliClient and write a flat-JSON manifest.

    Args:
        mutations: List of mutation dicts, each with at least an "action" field
                   ("create", "update", or "delete").
        pass_id:   Unique identifier for this reconciliation pass.
        repo_root: Repository root directory. Defaults to four levels above this file.

    Returns:
        Path to the written manifest file.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    acli = _load_acli()
    client = acli.AcliClient()

    mutations_with_outcomes: list[dict] = []

    for mutation in mutations:
        action = mutation.get("action", "")
        outcome = dict(mutation)

        if action == "create":
            result = create_one(mutation, client)
            outcome["result"] = result
        elif action == "update":
            result = update_one(mutation, client)
            outcome["result"] = result
        elif action == "delete":
            delete_one(mutation, client)
            outcome["result"] = None
        else:
            outcome["result"] = None
            outcome["error"] = f"unknown action: {action!r}"

        mutations_with_outcomes.append(outcome)

    manifest = {
        "pass_id": pass_id,
        "mutation_count": len(mutations),
        "mutations": mutations_with_outcomes,
    }

    snapshots_dir = repo_root / "bridge_state" / "snapshots"
    snapshots_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = snapshots_dir / f"{pass_id}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))

    return manifest_path
