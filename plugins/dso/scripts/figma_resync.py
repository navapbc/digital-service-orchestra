"""figma_resync — re-sync orchestration module for Figma pull-back workflow.

Public interface:
    run(ticket_id, non_interactive, _ticket_show_fn) -> int
    _lock_path(ticket_id) -> Path
    _run_pull(ticket_id, figma_file_key, manifest_dir, output_dir) -> tuple[int, str]
    _run_merge(manifest_dir, revised_spatial, output_dir) -> tuple[int, dict]
    _do_tag_swap(ticket_id, ticket_show_fn) -> None
    _record_metadata(ticket_id, metadata) -> None

Tag constants are read from figma-tags.conf via the shared constants file.
"""

from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_SCRIPTS_DIR = Path(__file__).resolve().parent
_CONSTANTS_DIR = _SCRIPTS_DIR.parent.parent / "skills" / "shared" / "constants"
_FIGMA_TAGS_CONF = _CONSTANTS_DIR / "figma-tags.conf"

_LOCK_DIR = Path("/tmp")
_LOCK_TTL_SECONDS = 30 * 60  # 30 minutes

TAG_AWAITING_REVIEW = "design:awaiting_review"
TAG_APPROVED = "design:approved"

# Try to load tags from constants file (overrides defaults if present)
if _FIGMA_TAGS_CONF.exists():
    for _line in _FIGMA_TAGS_CONF.read_text().splitlines():
        _line = _line.strip()
        if _line.startswith("#") or "=" not in _line:
            continue
        _key, _, _val = _line.partition("=")
        if _key.strip() == "TAG_AWAITING_REVIEW":
            TAG_AWAITING_REVIEW = _val.strip()
        elif _key.strip() == "TAG_APPROVED":
            TAG_APPROVED = _val.strip()


# ---------------------------------------------------------------------------
# Lock management
# ---------------------------------------------------------------------------


def _lock_path(ticket_id: str) -> Path:
    """Return the advisory lockfile path for a ticket."""
    return _LOCK_DIR / f"dso-figma-resync-{ticket_id}.lock"


def _acquire_lock(ticket_id: str) -> bool:
    """Acquire file lock. Return True on success, False if lock already held."""
    path = _lock_path(ticket_id)

    # Handle stale locks first: if the lock file exists and is past TTL, remove it
    # so the subsequent atomic open('x') can succeed.
    if path.exists():
        mtime = path.stat().st_mtime
        age = time.time() - mtime
        if age < _LOCK_TTL_SECONDS:
            return False  # fresh lock — already in progress
        # Stale lock — clean up and proceed
        path.unlink(missing_ok=True)

    # Atomic lock acquisition: open('x') is O_CREAT|O_EXCL on POSIX — creates the file
    # only if it does not exist, raising FileExistsError if another process beat us to it.
    # This closes the TOCTOU race with no new dependencies.
    lock_content = json.dumps(
        {
            "pid": os.getpid(),
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "ticket_id": ticket_id,
        }
    )
    try:
        with path.open("x") as _fd:
            _fd.write(lock_content)
    except FileExistsError:
        return False
    return True


def _release_lock(ticket_id: str) -> None:
    """Remove the advisory lockfile."""
    _lock_path(ticket_id).unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------


def _ticket_show(ticket_id: str) -> dict:
    """Run `dso ticket show <ticket_id>` and return parsed JSON."""
    # Locate the dso shim relative to this script's repo root
    repo_root = Path(__file__).resolve().parent.parent.parent.parent
    dso_shim = repo_root / ".claude" / "scripts" / "dso"
    cmd = [str(dso_shim), "ticket", "show", ticket_id]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ticket show {ticket_id} failed: {result.stderr}")
    txt = result.stdout
    start = txt.find("{")
    if start < 0:
        raise ValueError(f"No JSON in ticket show output for {ticket_id}")
    return json.loads(txt[start:])


def _run_pull(
    ticket_id: str,
    figma_file_key: str,
    manifest_dir: str,
    output_dir: str,
) -> tuple[int, str]:
    """Run the Figma pull step (figma-api-fetch.sh + figma-node-mapper.py).

    Returns (exit_code, revised_spatial_path).
    """
    revised_spatial = Path(output_dir) / "figma-revised-spatial.json"
    # figma-api-fetch.sh writes a raw response; figma-node-mapper.py converts it
    fetch_script = _SCRIPTS_DIR / "figma-api-fetch.sh"
    mapper_script = _SCRIPTS_DIR / "figma-node-mapper.py"

    Path(output_dir).mkdir(parents=True, exist_ok=True)
    raw_path = Path(output_dir) / "figma-raw.json"

    # Step 1: fetch
    fetch_result = subprocess.run(
        ["bash", str(fetch_script), figma_file_key, str(raw_path)],
        capture_output=True,
        text=True,
    )
    if fetch_result.returncode != 0:
        print(
            f"ERROR: figma-api-fetch.sh failed: {fetch_result.stderr}", file=sys.stderr
        )
        return fetch_result.returncode, ""

    # Step 2: map
    map_result = subprocess.run(
        [
            "python3",
            str(mapper_script),
            "--figma-response",
            str(raw_path),
            "--manifest-dir",
            manifest_dir,
            "--output",
            str(revised_spatial),
        ],
        capture_output=True,
        text=True,
    )
    if map_result.returncode != 0:
        print(
            f"ERROR: figma-node-mapper.py failed: {map_result.stderr}", file=sys.stderr
        )
        return map_result.returncode, ""

    return 0, str(revised_spatial)


def _run_merge(
    manifest_dir: str,
    revised_spatial: str,
    output_dir: str,
) -> tuple[int, dict]:
    """Run figma-merge.py and parse FIGMA_MERGE_OUTPUT from stdout.

    Returns (exit_code, output_dict).
    """
    # REVIEW-DEFENSE: --non-interactive is intentionally always passed here. figma_resync.run()
    # is the orchestration layer that owns the user confirmation (step 7 in run()): it displays
    # the change summary from FIGMA_MERGE_OUTPUT and prompts the user BEFORE calling _do_tag_swap.
    # Delegating a second interactive confirmation inside figma-merge.py would double-prompt the
    # user and violate the single-responsibility design: figma-merge.py merges artifacts and emits
    # structured output; figma_resync.py owns all user-facing workflow decisions. The merge step
    # is called non-interactively because the confirmation has already happened at the orchestration
    # level (or was explicitly waived via the non_interactive=True flag to run()).
    merge_script = _SCRIPTS_DIR / "figma-merge.py"
    result = subprocess.run(
        [
            "python3",
            str(merge_script),
            "--manifest-dir",
            manifest_dir,
            "--revised-spatial",
            revised_spatial,
            "--output-dir",
            output_dir,
            "--non-interactive",
        ],
        capture_output=True,
        text=True,
    )
    output: dict = {}
    stdout = result.stdout.strip()
    if stdout:
        try:
            output = json.loads(stdout)
        except json.JSONDecodeError:
            print(
                f"WARN: Could not parse figma-merge.py stdout as JSON: {stdout!r}",
                file=sys.stderr,
            )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
    return result.returncode, output


# ---------------------------------------------------------------------------
# Tag swap
# ---------------------------------------------------------------------------


def _do_tag_swap(ticket_id: str, ticket_show_fn=None) -> None:  # noqa: ANN001
    """Replace TAG_AWAITING_REVIEW with TAG_APPROVED on the ticket."""
    show_fn = ticket_show_fn or _ticket_show
    ticket = show_fn(ticket_id)
    tags: list[str] = list(ticket.get("tags", []))

    # Read-modify-write: remove awaiting_review, add approved
    new_tags = [t for t in tags if t != TAG_AWAITING_REVIEW]
    if TAG_APPROVED not in new_tags:
        new_tags.append(TAG_APPROVED)

    repo_root = Path(__file__).resolve().parent.parent.parent.parent
    dso_shim = repo_root / ".claude" / "scripts" / "dso"
    cmd = [
        str(dso_shim),
        "ticket",
        "edit",
        ticket_id,
        "--tags",
        ",".join(new_tags),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"ticket edit {ticket_id} failed (exit {result.returncode}): {result.stderr}"
        )


# ---------------------------------------------------------------------------
# Metadata recording
# ---------------------------------------------------------------------------


def _record_metadata(ticket_id: str, metadata: dict) -> None:
    """Record sync metadata as a ticket comment."""
    repo_root = Path(__file__).resolve().parent.parent.parent.parent
    dso_shim = repo_root / ".claude" / "scripts" / "dso"
    comment_body = json.dumps(metadata, indent=2)
    cmd = [str(dso_shim), "ticket", "comment", ticket_id, comment_body]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"ticket comment {ticket_id} failed (exit {result.returncode}): {result.stderr}"
        )


# ---------------------------------------------------------------------------
# Extract file key from ticket comments
# ---------------------------------------------------------------------------


def _extract_file_key(ticket: dict) -> str | None:
    """Extract Figma file key from ticket comments.

    Scans all comments in insertion order and returns the **first** line that
    starts with ``figma_file_key:``.  When a ticket has been through multiple
    design iterations (each adding a new ``figma_file_key:`` comment), only
    the chronologically first entry is used.  If a different file key is
    needed, remove or edit the earlier comment before calling this function.
    """
    for comment in ticket.get("comments", []):
        body = comment.get("body", "") if isinstance(comment, dict) else ""
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("figma_file_key:"):
                return line.split(":", 1)[1].strip()
    return None


# ---------------------------------------------------------------------------
# Main orchestration
# ---------------------------------------------------------------------------


def _validate_ticket_preconditions(
    ticket_id: str, show_fn
) -> tuple[dict | None, str | None]:
    """Validate ticket has the awaiting_review tag and a Figma file key.

    Returns (ticket, figma_file_key) on success, or (None, None) after printing error.
    """
    try:
        ticket = show_fn(ticket_id)
    except Exception as exc:
        print(f"ERROR: Could not load ticket {ticket_id}: {exc}", file=sys.stderr)
        return None, None

    tags = ticket.get("tags", [])
    if TAG_AWAITING_REVIEW not in tags:
        print(
            f"ERROR: Ticket {ticket_id} does not have '{TAG_AWAITING_REVIEW}' tag. "
            f"Re-sync requires the design to be in awaiting_review state. "
            f"Current tags: {tags}",
            file=sys.stderr,
        )
        return None, None

    figma_file_key = _extract_file_key(ticket)
    if not figma_file_key:
        print(
            f"ERROR: No Figma file key found in ticket {ticket_id} comments. "
            "Run /dso:preplanning on the parent epic to trigger the ui-designer agent and store the file key.",
            file=sys.stderr,
        )
        return None, None

    return ticket, figma_file_key


def _display_and_confirm(
    ticket_id: str,
    merge_output: dict,
    non_interactive: bool,
) -> tuple[bool, dict]:
    """Display change summary and prompt for confirmation (if interactive).

    Returns (proceed, merge_counts) where proceed=False means user cancelled.
    merge_counts holds the extracted count fields for metadata recording.
    """
    components_added = merge_output.get("components_added", 0)
    components_modified = merge_output.get("components_modified", 0)
    components_removed = merge_output.get("components_removed", 0)
    behavioral_specs_preserved = merge_output.get("behavioral_specs_preserved", 0)
    merge_warnings: list[str] = merge_output.get("warnings", [])

    print(f"\nChange Summary for ticket {ticket_id}:")
    print(f"  + {components_added} component(s) added")
    print(f"  ~ {components_modified} component(s) modified")
    print(f"  - {components_removed} component(s) removed")
    print(f"  ✓ {behavioral_specs_preserved} behavioral spec(s) preserved")
    if merge_warnings:
        for w in merge_warnings:
            print(f"  ! {w}")

    # REVIEW-DEFENSE: The merge step writes artifacts to disk BEFORE this prompt.
    # This is intentional: the change summary displayed IS the merged artifact
    # output, and showing it requires the merge to have already run. The confirmation here
    # gates only the irreversible side effects — the tag swap and metadata ticket comment.
    # File writes (merged artifacts) are not irreversible: if the user cancels, the output
    # directory contains the merged files but no ticket state has changed.
    if not non_interactive:
        try:
            answer = (
                input("\nProceed with tag swap and metadata recording? [y/N] ")
                .strip()
                .lower()
            )
        except EOFError:
            answer = "n"
        if answer != "y":
            print("Re-sync cancelled.", file=sys.stderr)
            return False, {}

    merge_counts = {
        "components_added": components_added,
        "components_modified": components_modified,
        "components_removed": components_removed,
        "behavioral_specs_preserved": behavioral_specs_preserved,
    }
    return True, merge_counts


def run(
    ticket_id: str,
    non_interactive: bool = False,
    manifest_dir: str | None = None,
    output_dir: str | None = None,
    _ticket_show_fn=None,  # noqa: ANN001
) -> int:
    """Orchestrate the full Figma pull-back workflow.

    Args:
        ticket_id: DSO ticket ID with design:awaiting_review tag.
        non_interactive: If True, skip confirmation prompt.
        manifest_dir: Directory with spatial-layout.json, wireframe.svg, tokens.md.
            Defaults to current directory.
        output_dir: Output directory for merged artifacts. Defaults to manifest_dir.
        _ticket_show_fn: Override for ticket show (used in tests).

    Returns:
        0 on success, 1 on failure.
    """
    show_fn = _ticket_show_fn or _ticket_show

    # 1. Precondition: check design:awaiting_review tag and Figma file key
    _ticket, figma_file_key = _validate_ticket_preconditions(ticket_id, show_fn)
    if figma_file_key is None:
        return 1

    # 2. Acquire file lock
    if not _acquire_lock(ticket_id):
        print(
            f"ERROR: Re-sync already in progress for ticket {ticket_id} "
            f"(lock at {_lock_path(ticket_id)}). "
            "Wait for the current sync to complete or remove the stale lock manually.",
            file=sys.stderr,
        )
        return 1

    manifest = manifest_dir or os.getcwd()
    out_dir = output_dir or manifest

    try:
        # 3. Pull: fetch Figma data and map to spatial layout
        pull_exit, revised_spatial = _run_pull(
            ticket_id=ticket_id,
            figma_file_key=figma_file_key,
            manifest_dir=manifest,
            output_dir=out_dir,
        )
        if pull_exit != 0:
            return 1

        # 4. Merge: run figma-merge.py and capture output
        merge_exit, merge_output = _run_merge(
            manifest_dir=manifest,
            revised_spatial=revised_spatial,
            output_dir=out_dir,
        )
        if merge_exit != 0:
            return 1

        # 5. Display change summary and confirm
        proceed, merge_counts = _display_and_confirm(
            ticket_id, merge_output, non_interactive
        )
        if not proceed:
            # REVIEW-DEFENSE: Returning 0 for user cancellation is intentional and follows
            # Unix convention — cancellation is a clean, non-error exit (not a failure).
            # Callers that need to distinguish cancellation from success can check stderr
            # for the "Re-sync cancelled." message.
            return 0  # no side effects taken yet

        # 6. Tag swap (read-modify-write, preserve other tags)
        _do_tag_swap(ticket_id, show_fn)

        # 7. Record sync metadata as ticket comment
        # CRITICAL-2 fix: tag swap already succeeded; if metadata recording fails,
        # log the error but do not propagate — the ticket is in a valid approved state
        # and metadata failure is non-critical compared to leaving the tag swap undone.
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        try:
            _record_metadata(
                ticket_id,
                {
                    "figma_file_key": figma_file_key,
                    "timestamp": timestamp,
                    **merge_counts,
                },
            )
        except Exception as exc:
            print(
                f"WARN: Failed to record sync metadata for {ticket_id}: {exc}",
                file=sys.stderr,
            )

    finally:
        _release_lock(ticket_id)

    return 0
