#!/usr/bin/env python3
"""Ticket graph engine: dependency traversal, cycle detection, ready_to_work, cache.

Reads compiled ticket state via ticket-reducer.py (imported via importlib for the
hyphenated filename) and builds a dependency graph for a given ticket.

Public API:
    build_dep_graph(ticket_id: str, tracker_dir: str) -> dict
    check_would_create_cycle(source_id: str, target_id: str, relation: str,
                             tracker_dir: str) -> bool
    add_dependency(source_id: str, target_id: str, tracker_dir: str,
                   relation: str = "blocks") -> None
    resolve_hierarchy_link(source_id: str, target_id: str,
                           tracker_dir: str) -> dict
    check_cycle_at_level(source_id: str, target_id: str, level: str,
                         tracker_dir: str) -> bool
    CyclicDependencyError (exception class)

CLI:
    python3 ticket-graph.py <ticket_id> [--tickets-dir=<path>]
    python3 ticket-graph.py --link <source> <target> <relation>
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import uuid
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Import ticket-reducer via importlib (hyphenated filename)
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).resolve().parent
_REDUCER_PATH = _SCRIPT_DIR / "ticket-reducer.py"


def _load_reducer() -> Any:
    spec = importlib.util.spec_from_file_location("ticket_reducer", _REDUCER_PATH)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load ticket-reducer.py from {_REDUCER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


_reducer = _load_reducer()
_reduce_ticket = _reducer.reduce_ticket


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class CyclicDependencyError(Exception):
    """Raised when adding a dependency would create a cycle."""

    pass


# ---------------------------------------------------------------------------
# Ticket status resolution (tombstone-aware)
# ---------------------------------------------------------------------------

_BLOCKING_RELATIONS = frozenset({"blocks", "depends_on"})


# REVIEW-DEFENSE: _get_ticket_status is defined here and called at lines ~307 and ~536
# (inside build_graph() and add_link()). The reviewer noted the function "may not exist"
# — it does exist and is the authoritative status resolver for graph operations.
def _get_ticket_status(ticket_id: str, tracker_dir: str) -> str:
    """Return the effective status of a ticket.

    Tombstone-awareness rules:
    - Directory absent → treat as "closed" (archived/tombstoned)
    - Directory contains .tombstone.json → read its 'status' field
    - reduce_ticket() returns None → treat as "closed" (ghost ticket safety)
    - reduce_ticket() returns error-state → treat as "closed"
    """
    ticket_dir = os.path.join(tracker_dir, ticket_id)

    # Missing directory → archived/tombstoned → closed
    if not os.path.isdir(ticket_dir):
        return "closed"

    # .tombstone.json present → read its status
    tombstone_path = os.path.join(ticket_dir, ".tombstone.json")
    if os.path.isfile(tombstone_path):
        try:
            with open(tombstone_path, encoding="utf-8") as f:
                tombstone = json.load(f)
            return str(tombstone.get("status", "closed"))
        except (OSError, json.JSONDecodeError):
            return "closed"

    # Reduce the ticket to get its compiled state
    try:
        state = _reduce_ticket(ticket_dir)
    except Exception:
        return "closed"

    if state is None:
        return "closed"

    # Error-state dicts (ghost tickets, corrupt CREATE)
    if isinstance(state, dict) and state.get("status") in ("error", "fsck_needed"):
        return "closed"

    return str(state.get("status", "open"))


# ---------------------------------------------------------------------------
# Direct-blocker discovery
# ---------------------------------------------------------------------------


def _find_direct_blockers(
    ticket_id: str,
    tracker_dir: str,
    exclude_archived: bool = True,
    ticket_states: dict[str, Any] | None = None,
) -> list[str]:
    """Return a list of ticket IDs that directly block ticket_id.

    Two sources of blocking relations:
    1. ticket_id's own deps with relation == 'depends_on':
       ticket_id depends on these tickets → they block it.
    2. Other tickets' deps with relation == 'blocks' and target_id == ticket_id:
       those tickets block ticket_id.

    Args:
        exclude_archived: When True (default), skip blockers whose compiled state
            has state.get('archived') == True.
        ticket_states: Optional pre-loaded dict keyed by ticket_id with compiled
            state dicts. When provided, avoids per-ticket _reduce_ticket calls.
            When None, loads all ticket states via reduce_all_tickets.
    """
    # Build ticket_states from reduce_all_tickets if not provided
    if ticket_states is None:
        all_states = _reducer.reduce_all_tickets(tracker_dir, exclude_archived=False)
        ticket_states = {}
        for t in all_states:
            tid = t.get("ticket_id", "")
            if tid and t.get("status") not in ("error", "fsck_needed"):
                ticket_states[tid] = t

    blockers: list[str] = []

    # Source 1: ticket_id's own compiled deps for 'depends_on'
    state = ticket_states.get(ticket_id)
    if state is not None and isinstance(state, dict):
        for dep in state.get("deps", []):
            if dep.get("relation") in _BLOCKING_RELATIONS:
                # For depends_on: target is what blocks this ticket
                # We only want depends_on here (blocks stored in blocker's dir)
                if dep.get("relation") == "depends_on":
                    target = dep.get("target_id", "")
                    if target and target not in blockers:
                        # Check if target is archived when filtering
                        if exclude_archived:
                            target_state = ticket_states.get(target)
                            if (
                                target_state is not None
                                and isinstance(target_state, dict)
                                and target_state.get("archived") is True
                            ):
                                continue
                        blockers.append(target)

    # Source 2: scan all ticket states for deps with relation=='blocks'
    # targeting ticket_id
    for entry, entry_state in ticket_states.items():
        if entry == ticket_id:
            continue

        if entry_state is None or not isinstance(entry_state, dict):
            continue

        # Skip archived entries when exclude_archived is True
        if exclude_archived and entry_state.get("archived") is True:
            continue

        for dep in entry_state.get("deps", []):
            if dep.get("relation") == "blocks" and dep.get("target_id") == ticket_id:
                if entry not in blockers:
                    blockers.append(entry)
                break  # Only need to add entry once

    return blockers


# ---------------------------------------------------------------------------
# Graph cache
# ---------------------------------------------------------------------------

_GRAPH_CACHE_FILE = ".graph-cache.json"


def _compute_cache_key(tracker_dir: str) -> str:
    """Compute a cache key from the sha256 of all ticket dirs' content hashes.

    Uses the same dir_hash method as the reducer: filename + file size.
    """
    try:
        entries = sorted(os.listdir(tracker_dir))
    except OSError:
        return ""

    all_hashes: list[str] = []
    for entry in entries:
        entry_path = os.path.join(tracker_dir, entry)
        if not os.path.isdir(entry_path):
            continue
        # Compute dir hash for this ticket dir (same method as reducer)
        try:
            dir_entries = sorted(os.listdir(entry_path))
        except OSError:
            dir_entries = []

        hash_parts: list[str] = []
        for name in dir_entries:
            if not name.endswith(".json") or name == ".cache.json":
                continue
            filepath = os.path.join(entry_path, name)
            try:
                size = os.path.getsize(filepath)
            except OSError:
                size = -1
            hash_parts.append(f"{name}:{size}")
        dir_hash = hashlib.sha256("|".join(hash_parts).encode()).hexdigest()
        all_hashes.append(f"{entry}:{dir_hash}")

    return hashlib.sha256("|".join(all_hashes).encode()).hexdigest()


def _read_graph_cache(tracker_dir: str, cache_key: str) -> dict[str, Any] | None:
    """Return cached graph data if the cache key matches, else None."""
    cache_path = os.path.join(tracker_dir, _GRAPH_CACHE_FILE)
    try:
        with open(cache_path, encoding="utf-8") as f:
            cached = json.load(f)
        if isinstance(cached, dict) and cached.get("cache_key") == cache_key:
            return cached.get("graphs", {})
    except (OSError, json.JSONDecodeError, KeyError):
        pass
    return None


def _write_graph_cache(
    tracker_dir: str, cache_key: str, graphs: dict[str, Any]
) -> None:
    """Atomically write the graph cache."""
    cache_path = os.path.join(tracker_dir, _GRAPH_CACHE_FILE)
    cache_tmp = cache_path + ".tmp"
    try:
        with open(cache_tmp, "w", encoding="utf-8") as f:
            json.dump({"cache_key": cache_key, "graphs": graphs}, f, ensure_ascii=False)
        os.rename(cache_tmp, cache_path)
    except OSError:
        pass  # Cache write failure is non-fatal


# ---------------------------------------------------------------------------
# build_dep_graph
# ---------------------------------------------------------------------------


def build_dep_graph(
    ticket_id: str, tracker_dir: str, exclude_archived: bool = True
) -> dict[str, Any]:
    """Build the dependency graph for a ticket.

    Returns:
        {
            "ticket_id": str,
            "deps": list[dict],   # raw dep entries from compiled state
            "blockers": list[str], # ticket IDs that directly block this ticket
            "children": list[str], # ticket IDs whose parent_id == ticket_id
            "ready_to_work": bool, # True when all direct blockers are closed/tombstoned
        }

    Uses a graph cache keyed by content hash of all ticket dirs.

    Args:
        exclude_archived: When True (default), archived tickets are excluded from
            children and blockers lists. Pass False to include archived tickets.
    """
    cache_key = _compute_cache_key(tracker_dir)

    # Only use cache for default (exclude_archived=True) to avoid stale results
    if cache_key and exclude_archived:
        cached_graphs = _read_graph_cache(tracker_dir, cache_key)
        if cached_graphs is not None and ticket_id in cached_graphs:
            return cached_graphs[ticket_id]

    # Compute the graph
    result = _compute_dep_graph(
        ticket_id, tracker_dir, exclude_archived=exclude_archived
    )

    # Update cache (only for default exclude_archived=True)
    if cache_key and exclude_archived:
        cached_graphs = _read_graph_cache(tracker_dir, cache_key) or {}
        cached_graphs[ticket_id] = result
        _write_graph_cache(tracker_dir, cache_key, cached_graphs)

    return result


def _compute_dep_graph(
    ticket_id: str, tracker_dir: str, exclude_archived: bool = True
) -> dict[str, Any]:
    """Compute (without cache) the dependency graph for ticket_id.

    Args:
        exclude_archived: When True (default), archived tickets are excluded from
            children and blockers lists.
    """
    # Pre-load all ticket states once to avoid per-ticket _reduce_ticket calls
    all_states_list = _reducer.reduce_all_tickets(tracker_dir, exclude_archived=False)
    ticket_states: dict[str, Any] = {}
    for t in all_states_list:
        tid = t.get("ticket_id", "")
        if tid and t.get("status") not in ("error", "fsck_needed"):
            ticket_states[tid] = t

    # Get the ticket's compiled deps list from pre-loaded state
    deps: list[dict[str, Any]] = []
    state = ticket_states.get(ticket_id)
    if state is not None and isinstance(state, dict):
        deps = list(state.get("deps", []))

    # Find direct blockers using pre-loaded ticket_states
    direct_blockers = _find_direct_blockers(
        ticket_id,
        tracker_dir,
        exclude_archived=exclude_archived,
        ticket_states=ticket_states,
    )

    # Find children: tickets whose parent_id matches this ticket (8cbf-e13b)
    children: list[str] = []
    for entry, child_state in ticket_states.items():
        if entry == ticket_id:
            continue
        if child_state is not None and isinstance(child_state, dict):
            if child_state.get("parent_id") == ticket_id:
                # Skip archived children when exclude_archived is True
                if exclude_archived and child_state.get("archived") is True:
                    continue
                children.append(entry)

    # Determine ready_to_work: all direct blockers must be closed/tombstoned
    ready_to_work = True
    for blocker_id in direct_blockers:
        status = _get_ticket_status(blocker_id, tracker_dir)
        if status != "closed":
            ready_to_work = False
            break

    return {
        "ticket_id": ticket_id,
        "deps": deps,
        "blockers": direct_blockers,
        "children": children,
        "ready_to_work": ready_to_work,
    }


# ---------------------------------------------------------------------------
# Cycle detection
# ---------------------------------------------------------------------------


def _get_all_blocked_by(ticket_id: str, tracker_dir: str) -> set[str]:
    """Return the set of all tickets (transitively) blocked by ticket_id.

    Uses BFS with a visited set to prevent infinite loops.
    ticket_id blocks X means X is in this set.
    """
    blocked: set[str] = set()
    queue: list[str] = [ticket_id]
    visited: set[str] = set()

    while queue:
        current = queue.pop(0)
        if current in visited:
            continue
        visited.add(current)

        # Find all tickets that current directly blocks
        current_dir = os.path.join(tracker_dir, current)
        if os.path.isdir(current_dir):
            try:
                state = _reduce_ticket(current_dir)
            except Exception:
                state = None

            if state is not None and isinstance(state, dict):
                for dep in state.get("deps", []):
                    if dep.get("relation") == "blocks":
                        target = dep.get("target_id", "")
                        if target:
                            blocked.add(target)
                            if target not in visited:
                                queue.append(target)

        # Also find tickets that current blocks via 'depends_on' stored in
        # the dependent's dir (tickets whose deps include depends_on→current)
        try:
            entries = os.listdir(tracker_dir)
        except OSError:
            entries = []

        for entry in entries:
            if entry in visited:
                continue
            entry_path = os.path.join(tracker_dir, entry)
            if not os.path.isdir(entry_path):
                continue
            try:
                e_state = _reduce_ticket(entry_path)
            except Exception:
                e_state = None
            if e_state is None or not isinstance(e_state, dict):
                continue
            for dep in e_state.get("deps", []):
                if (
                    dep.get("relation") == "depends_on"
                    and dep.get("target_id") == current
                ):
                    blocked.add(entry)
                    if entry not in visited:
                        queue.append(entry)

    return blocked


def check_would_create_cycle(
    source_id: str, target_id: str, relation: str, tracker_dir: str
) -> bool:
    """Return True if adding source_id→target_id would create a cycle.

    Only 'blocks' and 'depends_on' relations can create cycles.
    'relates_to' never creates cycles and always returns False.
    """
    if relation == "relates_to":
        return False

    # Adding source_id→target_id (source blocks target) creates a cycle if
    # target_id can already reach source_id (transitively blocks it).
    # i.e., if source_id is already in the set of things blocked by target_id.
    blocked_by_target = _get_all_blocked_by(target_id, tracker_dir)
    return source_id in blocked_by_target


def check_cycle_at_level(
    source_id: str, target_id: str, level: str, tracker_dir: str
) -> bool:
    """Return True if adding source_id→target_id would create a cycle at the given level.

    A self-loop (source_id == target_id) always returns True.

    Level-scoped detection: only considers tickets whose ticket_type matches `level`.
    If level is empty, fails open (returns False — no cycle detected).

    Uses BFS from target_id following 'blocks' and 'depends_on' edges, scoped to
    tickets of the same level. Returns True if source_id is reachable from target_id.
    """
    if not level:
        return False

    if source_id == target_id:
        return True

    # BFS from target_id: if we can reach source_id, adding source→target creates a cycle
    visited: set[str] = set()
    queue: list[str] = [target_id]

    while queue:
        current = queue.pop(0)
        if current in visited:
            continue
        visited.add(current)

        if current == source_id:
            return True

        current_dir = os.path.join(tracker_dir, current)
        if not os.path.isdir(current_dir):
            continue

        try:
            state = _reduce_ticket(current_dir)
        except Exception:
            continue

        if state is None or not isinstance(state, dict):
            continue

        # Only traverse edges at the same level
        current_level = state.get("ticket_type", "").lower()
        if current_level != level:
            continue

        for dep in state.get("deps", []):
            relation = dep.get("relation", "")
            if relation in ("blocks", "depends_on"):
                target = dep.get("target_id", "")
                if target and target not in visited:
                    # Check if the target is also at this level before queuing
                    target_dir = os.path.join(tracker_dir, target)
                    if os.path.isdir(target_dir):
                        try:
                            t_state = _reduce_ticket(target_dir)
                        except Exception:
                            t_state = None
                        if t_state and t_state.get("ticket_type", "").lower() == level:
                            queue.append(target)

    return False


# ---------------------------------------------------------------------------
# add_dependency
# ---------------------------------------------------------------------------


def _is_active_link(
    source_id: str, target_id: str, relation: str, tracker_dir: str
) -> bool:
    """Return True if a net-active LINK exists from source_id to target_id with the given relation.

    Replays LINK and UNLINK events in chronological order (same algorithm as ticket-link.sh's
    _is_duplicate_link) to determine the net-effective state.
    """
    import glob as _glob

    ticket_dir = os.path.join(tracker_dir, source_id)
    if not os.path.isdir(ticket_dir):
        return False

    # Collect all LINK and UNLINK event files and sort with a tie-breaker that
    # guarantees LINK always replays before UNLINK at the same Unix-second timestamp.
    # Sort key: (timestamp_segment, event_type_order, full_basename)
    # - timestamp_segment: first '-'-delimited field preserves chronological order
    # - event_type_order (LINK=0, UNLINK=1): LINK processes before UNLINK at same second,
    #   even when the UNLINK filename's UUID sorts alphabetically before the LINK's UUID
    # - full_basename: stable tiebreaker for remaining ambiguity within same type+timestamp
    _event_order = {"LINK": 0, "UNLINK": 1}
    link_files = [
        ("LINK", f) for f in _glob.glob(os.path.join(ticket_dir, "*-LINK.json"))
    ]
    unlink_files = [
        ("UNLINK", f) for f in _glob.glob(os.path.join(ticket_dir, "*-UNLINK.json"))
    ]
    all_events = sorted(
        link_files + unlink_files,
        key=lambda x: (
            os.path.basename(x[1]).split("-")[0],
            _event_order.get(x[0], 99),
            os.path.basename(x[1]),
        ),
    )

    # Replay events to determine net-active links
    active_links: dict[str, tuple[str, str]] = {}  # uuid → (target_id, relation)
    for event_type, filepath in all_events:
        try:
            with open(filepath, encoding="utf-8") as fh:
                ev = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        ev_uuid = ev.get("uuid", "")
        data = ev.get("data", {})
        if event_type == "LINK" and ev_uuid:
            active_links[ev_uuid] = (
                data.get("target_id", data.get("target", "")),
                data.get("relation", ""),
            )
        elif event_type == "UNLINK":
            link_uuid = data.get("link_uuid", "")
            if link_uuid:
                active_links.pop(link_uuid, None)

    # Check if (target_id, relation) pair is net-active
    return any(
        tid == target_id and rel == relation for tid, rel in active_links.values()
    )


def _write_link_event(
    source_id: str,
    target_id: str,
    relation: str,
    tracker_dir: str,
) -> None:
    """Write a single LINK event to source_id's directory (no cycle check, no idempotency)."""
    import time

    source_dir = os.path.join(tracker_dir, source_id)
    if not os.path.isdir(source_dir):
        os.makedirs(source_dir, exist_ok=True)

    link_uuid = str(uuid.uuid4())
    timestamp = int(time.time())

    link_event = {
        "event_type": "LINK",
        "uuid": link_uuid,
        "timestamp": timestamp,
        "author": "ticket-graph",
        "env_id": "00000000-0000-4000-8000-000000000000",
        "data": {
            "target_id": target_id,
            "relation": relation,
        },
    }

    filename = f"{timestamp}-{link_uuid}-LINK.json"
    event_path = os.path.join(source_dir, filename)
    with open(event_path, "w", encoding="utf-8") as f:
        json.dump(link_event, f, ensure_ascii=False)


def add_dependency(
    source_id: str,
    target_id: str,
    tracker_dir: str,
    relation: str = "blocks",
) -> None:
    """Add a dependency from source_id to target_id with cycle check.

    Raises CyclicDependencyError if adding this dependency would create a cycle.
    Writes a LINK event to the source ticket's directory.
    Idempotent: if a net-active LINK with the same (target_id, relation) already exists,
    this is a no-op (exits cleanly without writing a duplicate event).
    For relates_to: also writes a reciprocal LINK event in target_id's directory.

    Args:
        source_id: The ticket that blocks/depends on target_id.
        target_id: The ticket being blocked/depended upon.
        tracker_dir: Path to the .tickets-tracker directory.
        relation: One of 'blocks', 'depends_on', 'relates_to'. Defaults to 'blocks'.
    """
    # Step 1: Resolve hierarchy — promote cross-hierarchy links to the correct level.
    # Must happen before cycle check so that the cycle check operates on resolved IDs.
    hierarchy_result = resolve_hierarchy_link(source_id, target_id, tracker_dir)

    # Handle error from hierarchy resolver (unreadable/missing ticket)
    if "error" in hierarchy_result:
        raise ValueError(hierarchy_result["error"])

    # Handle redundant link (source is direct parent/child of target)
    if hierarchy_result.get("is_redundant"):
        msg = (
            f"ERROR: redundant link — {source_id} and {target_id} are in a direct "
            "parent-child relationship"
        )
        print(msg, file=sys.stderr)
        raise ValueError(msg)

    resolved_source = str(hierarchy_result["resolved_source"])
    resolved_target = str(hierarchy_result["resolved_target"])
    was_redirected = bool(hierarchy_result.get("was_redirected"))

    # Handle redirect: print notice + machine-readable JSON, use resolved IDs
    if was_redirected:
        print(
            f"REDIRECT: {source_id}\u2192{target_id} promoted to "
            f"{resolved_source}\u2192{resolved_target}",
            file=sys.stderr,
        )
        print(
            json.dumps(
                {
                    "redirected": True,
                    "original": {"source": source_id, "target": target_id},
                    "resolved": {"source": resolved_source, "target": resolved_target},
                }
            )
        )

    # Use resolved IDs for all remaining operations
    source_id = resolved_source
    target_id = resolved_target

    if check_would_create_cycle(source_id, target_id, relation, tracker_dir):
        raise CyclicDependencyError(
            f"Adding {resolved_source} → {resolved_target} ({relation}) would create a cycle"
        )

    # Level-scoped cycle detection on resolved pair
    resolved_source_dir = os.path.join(tracker_dir, resolved_source)
    resolved_source_state = (
        _reduce_ticket(resolved_source_dir)
        if os.path.isdir(resolved_source_dir)
        else None
    )
    level = (
        (resolved_source_state.get("ticket_type") or "").lower()
        if resolved_source_state
        else ""
    )
    if level and check_cycle_at_level(
        resolved_source, resolved_target, level, tracker_dir
    ):
        if resolved_source == resolved_target:
            raise CyclicDependencyError(
                f"Adding {resolved_source} → {resolved_target} ({relation}) "
                f"is a self-referential dependency at {level} level"
            )
        raise CyclicDependencyError(
            f"Adding {resolved_source} → {resolved_target} ({relation}) "
            f"would create a cycle at {level} level"
        )

    # Guard: cannot write any LINK event for a closed source ticket.
    # A closed ticket is frozen — adding new dependency/relation events to it
    # bypasses the closed-ticket invariant and can introduce children after close.
    # Fail-open: _get_ticket_status treats missing tickets as "closed", so we
    # only block when the status is explicitly "closed" from a readable state.
    source_status = _get_ticket_status(source_id, tracker_dir)
    if source_status == "closed":
        raise ValueError(
            f"cannot create {relation} link — source ticket '{source_id}' is closed. "
            f"Reopen it first with: ticket transition {source_id} closed open"
        )

    # Guard: cannot create a depends_on link to a closed ticket
    if relation == "depends_on":
        target_status = _get_ticket_status(target_id, tracker_dir)
        if target_status == "closed":
            raise ValueError(
                f"cannot create depends_on link — target ticket '{target_id}' is closed"
            )

    # Idempotency: skip if the net-active state already has this link
    if _is_active_link(source_id, target_id, relation, tracker_dir):
        return

    # Write LINK event to source ticket's directory
    _write_link_event(source_id, target_id, relation, tracker_dir)

    # For relates_to: also write reciprocal LINK in target's directory
    if relation == "relates_to" and not _is_active_link(
        target_id, source_id, relation, tracker_dir
    ):
        _write_link_event(target_id, source_id, relation, tracker_dir)


# ---------------------------------------------------------------------------
# Hierarchy resolver
# ---------------------------------------------------------------------------


def _get_ancestors(ticket_id: str, tracker_dir: str, max_hops: int = 2) -> list[str]:
    """Return the ancestor chain for ticket_id up to max_hops hops.

    Returns a list starting from ticket_id itself, then its parent_id,
    then grandparent_id (if any), up to max_hops levels up.

    E.g., for task→story→epic, returns [task_id, story_id, epic_id].
    Returns [ticket_id] if the ticket has no parent or is unreadable.
    """
    chain: list[str] = [ticket_id]
    current = ticket_id
    for _ in range(max_hops):
        ticket_dir = os.path.join(tracker_dir, current)
        if not os.path.isdir(ticket_dir):
            break
        try:
            state = _reduce_ticket(ticket_dir)
        except Exception:
            state = None
        if state is None:
            break
        parent_id = state.get("parent_id")
        if not parent_id:
            break
        chain.append(parent_id)
        current = parent_id
    return chain


def resolve_hierarchy_link(
    source_id: str,
    target_id: str,
    tracker_dir: str,
) -> dict[str, object]:
    """Resolve the effective hierarchy link target for a (source, target) ticket pair.

    Walks each ticket's parent_id chain (≤2 hops) using _reduce_ticket, finds the
    divergence point in the hierarchy, and returns a dict:
        {
            "resolved_source": str,   # effective source (may be ancestor)
            "resolved_target": str,   # effective target (may be ancestor)
            "was_redirected": bool,   # True if either ID was redirected to an ancestor
            "is_redundant": bool,     # True if source is direct parent of target or vice versa
        }

    On error (unreadable ticket):
        {"error": str, "ticket_id": str}  with the caller expected to exit non-zero.

    Args:
        source_id: Source ticket ID.
        target_id: Target ticket ID.
        tracker_dir: Path to the .tickets-tracker directory.
    """
    # Validate both tickets exist (SC11: unreadable ticket → error)
    source_dir = os.path.join(tracker_dir, source_id)
    target_dir = os.path.join(tracker_dir, target_id)

    if not os.path.isdir(source_dir):
        return {"error": f"ticket '{source_id}' does not exist", "ticket_id": source_id}
    if not os.path.isdir(target_dir):
        return {"error": f"ticket '{target_id}' does not exist", "ticket_id": target_id}

    # Try reducing both tickets — error if unreadable
    try:
        source_state = _reduce_ticket(source_dir)
    except Exception:
        source_state = None
    if source_state is None:
        return {
            "error": f"ticket '{source_id}' could not be reduced",
            "ticket_id": source_id,
        }

    try:
        target_state = _reduce_ticket(target_dir)
    except Exception:
        target_state = None
    if target_state is None:
        return {
            "error": f"ticket '{target_id}' could not be reduced",
            "ticket_id": target_id,
        }

    # Walk ancestor chains (≤2 hops each)
    source_chain = _get_ancestors(source_id, tracker_dir, max_hops=2)
    target_chain = _get_ancestors(target_id, tracker_dir, max_hops=2)

    # Check is_redundant: source is direct parent of target or target is direct parent of source
    source_parent = source_state.get("parent_id")
    target_parent = target_state.get("parent_id")
    is_redundant = (source_id == target_parent) or (target_id == source_parent)

    # Find divergence point: walk up both chains together until they share an ancestor
    # The effective resolved IDs are the highest ancestor before the shared node
    # (i.e., the last distinct ancestor in each chain before they converge).

    # Build set for quick membership check
    target_ancestors = set(target_chain)

    # Find the first shared ancestor (if any) — this is the convergence point
    shared: str | None = None
    for ancestor in source_chain:
        if ancestor in target_ancestors:
            shared = ancestor
            break

    if shared is None:
        # No shared ancestor — chains are fully separate (cross-epic or orphans)
        # Use the root of each chain (last element)
        resolved_source = source_chain[-1]
        resolved_target = target_chain[-1]
    else:
        # Shared ancestor found — resolved IDs are the last element in each chain
        # *before* reaching the shared ancestor
        def _last_before(chain: list[str], shared_id: str) -> str:
            idx = chain.index(shared_id)
            return chain[idx - 1] if idx > 0 else chain[0]

        resolved_source = _last_before(source_chain, shared)
        resolved_target = _last_before(target_chain, shared)

    was_redirected = (resolved_source != source_id) or (resolved_target != target_id)

    return {
        "resolved_source": resolved_source,
        "resolved_target": resolved_target,
        "was_redirected": was_redirected,
        "is_redundant": is_redundant,
    }


# ---------------------------------------------------------------------------
# Archive eligibility
# ---------------------------------------------------------------------------


def compute_archive_eligible(tracker_dir: str) -> list[str]:
    """Return closed ticket IDs eligible for archival.

    A closed ticket is eligible if it is NOT reachable from any open ticket
    via depends_on or blocks edges (traversed bidirectionally), and is not
    already archived.

    Algorithm:
    1. Load all tickets (including archived) via reduce_all_tickets.
    2. Build an adjacency list from depends_on and blocks edges (undirected).
    3. BFS from every non-closed, non-archived ticket.
    4. Closed, non-archived tickets NOT reached are eligible.
    """
    all_tickets = _reducer.reduce_all_tickets(tracker_dir, exclude_archived=False)

    # Index tickets by ID
    ticket_map: dict[str, dict[str, Any]] = {}
    for t in all_tickets:
        tid = t.get("ticket_id", "")
        if tid:
            ticket_map[tid] = t

    # Build undirected adjacency list for depends_on and blocks edges
    adj: dict[str, set[str]] = {tid: set() for tid in ticket_map}
    for tid, t in ticket_map.items():
        for dep in t.get("deps", []):
            relation = dep.get("relation", "")
            target = dep.get("target_id", "")
            if relation in ("depends_on", "blocks") and target:
                adj.setdefault(tid, set()).add(target)
                adj.setdefault(target, set()).add(tid)

    # Identify open (non-closed, non-archived) tickets as BFS seeds
    seeds: list[str] = []
    for tid, t in ticket_map.items():
        status = t.get("status", "open")
        archived = t.get("archived", False)
        if status != "closed" and not archived:
            seeds.append(tid)

    # BFS from all seeds
    reachable: set[str] = set()
    queue = list(seeds)
    visited: set[str] = set()
    while queue:
        current = queue.pop(0)
        if current in visited:
            continue
        visited.add(current)
        reachable.add(current)
        for neighbor in adj.get(current, set()):
            if neighbor not in visited:
                queue.append(neighbor)

    # Eligible: closed, not archived, not reachable
    eligible: list[str] = []
    for tid, t in ticket_map.items():
        status = t.get("status", "open")
        archived = t.get("archived", False)
        if status == "closed" and not archived and tid not in reachable:
            eligible.append(tid)

    return sorted(eligible)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main() -> int:
    """CLI entry point."""
    args = sys.argv[1:]

    if not args:
        print(
            "Usage: ticket-graph.py <ticket_id> [--tickets-dir=<path>]\n"
            "       ticket-graph.py --link <source> <target> <relation>",
            file=sys.stderr,
        )
        return 1

    # Resolve tracker_dir from --tickets-dir flag or default
    def _find_tracker_dir(args: list[str]) -> tuple[str, list[str]]:
        remaining = []
        tracker_dir = None
        for arg in args:
            if arg.startswith("--tickets-dir="):
                tracker_dir = arg.split("=", 1)[1]
            else:
                remaining.append(arg)
        if tracker_dir is None:
            try:
                import subprocess

                result = subprocess.run(
                    ["git", "rev-parse", "--show-toplevel"],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                repo_root = result.stdout.strip()
                tracker_dir = os.path.join(repo_root, ".tickets-tracker")
            except Exception:
                tracker_dir = os.path.join(os.getcwd(), ".tickets-tracker")
        return tracker_dir, remaining

    if args[0] == "resolve-hierarchy-link":
        # Usage: resolve-hierarchy-link <src> <tgt> --tickets-dir=<dir>
        remaining = args[1:]
        tracker_dir, pos_args = _find_tracker_dir(remaining)
        if len(pos_args) < 2:
            print(
                "Usage: ticket-graph.py resolve-hierarchy-link <source> <target>"
                " [--tickets-dir=<path>]",
                file=sys.stderr,
            )
            return 1
        source_id = pos_args[0]
        target_id = pos_args[1]
        result = resolve_hierarchy_link(source_id, target_id, tracker_dir)
        print(json.dumps(result, ensure_ascii=False))
        # Non-zero exit when result contains an error key
        if "error" in result:
            return 1
        return 0

    if args[0] == "--archive-eligible":
        tracker_dir, _ = _find_tracker_dir(args[1:])
        eligible = compute_archive_eligible(tracker_dir)
        print(json.dumps(eligible))
        return 0

    if args[0] == "--link":
        if len(args) < 4:
            print(
                "Usage: ticket-graph.py --link <source> <target> <relation>",
                file=sys.stderr,
            )
            return 1
        source_id = args[1]
        target_id = args[2]
        relation = args[3]
        tracker_dir, _ = _find_tracker_dir([])

        # Validate both tickets exist before writing a LINK event
        source_dir = os.path.join(tracker_dir, source_id)
        target_dir = os.path.join(tracker_dir, target_id)
        if not os.path.isdir(source_dir):
            print(f"Error: ticket '{source_id}' does not exist", file=sys.stderr)
            return 1
        if not os.path.isdir(target_dir):
            print(f"Error: ticket '{target_id}' does not exist", file=sys.stderr)
            return 1

        try:
            add_dependency(source_id, target_id, tracker_dir, relation)
        except CyclicDependencyError as e:
            print(f"Error: {e}", file=sys.stderr)
            return 1
        except ValueError as e:
            print(f"Error: {e}", file=sys.stderr)
            return 1
        return 0

    # Deps query mode
    # Extract --include-archived flag before resolving tracker_dir
    include_archived = "--include-archived" in args
    if include_archived:
        args = [a for a in args if a != "--include-archived"]

    tracker_dir, remaining_args = _find_tracker_dir(args)

    if not remaining_args:
        print(
            "Usage: ticket-graph.py <ticket_id> [--tickets-dir=<path>]",
            file=sys.stderr,
        )
        return 1

    ticket_id = remaining_args[0]

    # Validate ticket exists before querying
    ticket_dir = os.path.join(tracker_dir, ticket_id)
    if not os.path.isdir(ticket_dir):
        print(f"Error: ticket '{ticket_id}' does not exist", file=sys.stderr)
        return 1

    # Check if the target ticket is archived; error unless --include-archived passed
    if not include_archived:
        try:
            target_state = _reduce_ticket(ticket_dir)
        except Exception:
            target_state = None
        if target_state is not None and isinstance(target_state, dict):
            if target_state.get("archived") is True:
                print(
                    f"Error: ticket '{ticket_id}' is archived. "
                    "Use --include-archived to include archived tickets.",
                    file=sys.stderr,
                )
                return 1

    exclude_archived = not include_archived
    result = build_dep_graph(ticket_id, tracker_dir, exclude_archived=exclude_archived)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
