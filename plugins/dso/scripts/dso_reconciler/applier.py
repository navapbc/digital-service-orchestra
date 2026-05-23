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


def create_one(
    mutation: dict,
    client,
    rest_calls: int = 0,
    deferred_creates: list | None = None,
) -> dict | None:
    """Create a Jira issue from the mutation's fields, with budget guard and JQL dedup.

    Budget guard: if rest_calls >= 200, appends mutation to deferred_creates and
    returns None without issuing any REST calls.

    JQL dedup: searches for an existing issue with label 'dso-id:<local_id>' before
    creating. On hit, skips create_issue() and returns a dedup-create-skipped sentinel.
    On miss, proceeds with create_issue().

    Args:
        mutation:         Mutation dict with at least "fields" and optionally "local_id".
        client:           AcliClient instance.
        rest_calls:       Number of REST calls already issued in this pass.
        deferred_creates: List to append deferred mutations to (budget guard).

    Returns:
        The client.create_issue() result on miss, a dedup sentinel dict on hit,
        or None when the mutation is budget-deferred.
    """
    # Budget guard: defer without any REST call when at or over the limit
    if rest_calls >= 200:
        if deferred_creates is not None:
            deferred_creates.append(mutation)
        return None

    local_id = mutation.get("local_id", "")
    jql = f'labels = "dso-id:{local_id}"'
    hits = client.search_issues(jql)

    if hits:
        hit_key = hits[0].get("key", "")
        return {"status": "dedup-create-skipped", "key": hit_key}

    return client.create_issue(mutation.get("fields", {}))


def update_one(mutation: dict, client) -> dict:
    """Update an existing Jira issue from the mutation's key and fields. Returns the client result."""
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

    rest_calls: int = 0
    deferred_creates: list[dict] = []
    mutations_with_outcomes: list[dict] = []

    for mutation in mutations:
        action = mutation.get("action", "")
        outcome = dict(mutation)

        if action == "create":
            result = create_one(
                mutation,
                client,
                rest_calls=rest_calls,
                deferred_creates=deferred_creates,
            )
            # Only count REST call on actual create (not dedup-skipped, not deferred)
            if result is not None and result.get("status") != "dedup-create-skipped":
                rest_calls += 1
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
