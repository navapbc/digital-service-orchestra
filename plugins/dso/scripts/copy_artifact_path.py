#!/usr/bin/env python3
"""copy_artifact_path.py — Path validation helper for copy.artifact_dir config.

Validates and resolves artifact output paths for the gov-copy-writer workflow.
Rejects absolute paths, paths containing '..' segments, and paths that resolve
outside the project root after normalization.

Usage (CLI):
    python copy_artifact_path.py <artifact_dir> <epic_id> [--project-root <root>]

Exits 0 on success, printing the resolved path.
Exits 1 on validation failure, printing an error message to stderr.

Importable API:
    validate_artifact_path(path: str, project_root: Path) -> Path
    resolve_artifact_path(artifact_dir: str, epic_id: str, project_root: Path) -> Path
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def validate_artifact_path(path: str, project_root: Path) -> Path:
    """Validate *path* against safe-path rules and return the resolved Path.

    Rules (in order):
    1. Must not be an absolute path.
    2. Must not contain any '..' segments (checked before resolution to catch
       crafted inputs that normalise differently per OS).
    3. The resolved path must remain inside *project_root*.

    Args:
        path: The raw path string to validate (e.g. "copy/f360-3a5b.yaml").
        project_root: The canonical project root directory.  Treated as the
            trust boundary — the resolved path must be a descendant of this.

    Returns:
        The resolved absolute Path when all checks pass.

    Raises:
        ValueError: With a descriptive message when any check fails.
    """
    # Rule 1: reject absolute paths
    if Path(path).is_absolute():
        raise ValueError(
            f"absolute paths are not allowed for copy.artifact_dir; "
            f"got: {path!r}.  Use a relative path such as 'copy/'."
        )

    # Rule 2: reject '..' segments (pre-resolution)
    parts = Path(path).parts
    if any(part == ".." for part in parts):
        raise ValueError(
            f"Path traversal ('..') is not allowed in copy.artifact_dir; "
            f"got: {path!r}.  Paths must stay within the project root."
        )

    # Rule 3: resolve and check containment
    resolved = (project_root / path).resolve()
    project_root_resolved = project_root.resolve()

    try:
        resolved.relative_to(project_root_resolved)
    except ValueError:
        raise ValueError(
            f"Resolved path escapes the project root.  "
            f"project_root={project_root_resolved!r}, resolved={resolved!r}, "
            f"input={path!r}."
        ) from None

    return resolved


def resolve_artifact_path(
    artifact_dir: str,
    epic_id: str,
    project_root: Path,
) -> Path:
    """Combine *artifact_dir* and *epic_id* into a validated artifact path.

    Constructs ``<artifact_dir>/<epic_id>.yaml`` and validates the result
    against :func:`validate_artifact_path`.

    Args:
        artifact_dir: The value of the ``copy.artifact_dir`` config key
            (e.g. ``"copy/"``).  Must be a safe relative path.
        epic_id: The epic identifier string (e.g. ``"f360-3a5b-b8f3-4f86"``).
            The final filename will be ``<epic_id>.yaml``.
        project_root: Trust boundary — the project root directory.

    Returns:
        The resolved absolute Path to the artifact file.

    Raises:
        ValueError: When *artifact_dir* or the combined path fails validation.
    """
    # Strip trailing slash from artifact_dir for consistent joining
    artifact_dir_clean = artifact_dir.rstrip("/")
    combined = f"{artifact_dir_clean}/{epic_id}.yaml"
    return validate_artifact_path(combined, project_root=project_root)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Validate and resolve a copy artifact path.  "
            "Exits 0 and prints the resolved path on success, "
            "exits 1 with an error message on failure."
        )
    )
    parser.add_argument(
        "artifact_dir",
        help="Value of copy.artifact_dir config key (e.g. 'copy/').",
    )
    parser.add_argument(
        "epic_id",
        help="Epic identifier (e.g. 'f360-3a5b-b8f3-4f86').",
    )
    parser.add_argument(
        "--project-root",
        default=".",
        help="Project root directory (default: current working directory).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    project_root = Path(args.project_root).resolve()

    try:
        resolved = resolve_artifact_path(
            artifact_dir=args.artifact_dir,
            epic_id=args.epic_id,
            project_root=project_root,
        )
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(resolved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
