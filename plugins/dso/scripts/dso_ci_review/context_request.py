"""dso_ci_review.context_request — Structured-request parser and read_files handler.

Implements the CI Review Context-Request Contract (version 1).
See: docs/contracts/ci-review-context-request.md

Public API:
  - parse_request_blocks(messages): scan assistant-role messages for request blocks
  - execute_read_files(paths, repo_root, max_file_bytes): read files within repo-root jail
"""

from __future__ import annotations

import json
import logging
import os
import pathlib
import re

logger = logging.getLogger(__name__)

# Fenced JSON block pattern — matches ```json ... ``` or ``` ... ```
_FENCED_JSON_RE = re.compile(
    r"```(?:json)?\s*\n(.*?)\n```",
    re.DOTALL,
)

# Required field for a message to be treated as a context request
_ACTION_KEY = "action"
_SUPPORTED_ACTIONS = frozenset(["read_files"])

# Truncation marker appended when a file exceeds the size cap (contract §Security Notes)
_TRUNCATION_MARKER_TEMPLATE = (
    "\n[TRUNCATED: file exceeded {max_bytes} bytes"
    " — do not assert absence of content based on this truncated read]"
)


def _parse_fenced_json_blocks(content: str) -> list[dict]:
    """Extract and parse all fenced JSON blocks from *content*.

    Returns a list of successfully parsed dicts. Malformed JSON is silently
    skipped (contract §Parser Rules).
    """
    result = []
    for match in _FENCED_JSON_RE.finditer(content):
        raw = match.group(1).strip()
        try:
            obj = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(obj, dict):
            result.append(obj)
    return result


def _is_request_block(obj: dict) -> bool:
    """Return True iff *obj* matches the context-request schema (has 'action' field)."""
    return _ACTION_KEY in obj and obj[_ACTION_KEY] in _SUPPORTED_ACTIONS


def parse_request_blocks(messages: list[dict]) -> list[dict]:
    """Scan only assistant-role messages for structured request blocks.

    Contract §Parser Rules:
    - Only assistant-role messages are scanned.
    - User-role messages are never processed, even if they contain valid request JSON.
    - Malformed JSON blocks are silently skipped (no raise).
    - When an assistant message contains both a request block and a final-findings block,
      the request block takes precedence (contract §Request-Precedence Rule).

    Args:
        messages: List of message dicts with 'role' and 'content' keys.

    Returns:
        List of parsed request dicts. Empty list if no valid requests found.
    """
    requests: list[dict] = []

    for message in messages:
        role = message.get("role", "")
        if role != "assistant":
            # Contract: never parse user-role messages (injection defense)
            continue

        content = message.get("content", "")
        if not isinstance(content, str) or not content.strip():
            continue

        parsed_blocks = _parse_fenced_json_blocks(content)

        # Apply precedence rule: collect request blocks first; if any exist,
        # the findings blocks in the same turn are deferred (not returned here).
        turn_requests = [b for b in parsed_blocks if _is_request_block(b)]
        if turn_requests:
            requests.extend(turn_requests)
            # Precedence rule: request found — findings in same turn are deferred.
            # Do NOT add non-request blocks for this turn.

    return requests


def execute_read_files(
    paths: list[str],
    repo_root: str = ".",
    max_file_bytes: int = 262144,  # 256 KB default (contract §Security Notes)
) -> str:
    """Read files within the repo-root jail and return formatted content.

    Security (contract §Security Notes):
    - Absolute paths are rejected immediately.
    - Paths containing '..' sequences are rejected before canonicalization.
    - All paths are canonicalized via os.path.realpath() and verified to resolve
      within canonical(repo_root), defending against symlink escapes.
    - Files exceeding max_file_bytes are truncated; the truncation marker is appended.

    Args:
        paths: List of repository-relative file paths.
        repo_root: Absolute path to the repository root.
        max_file_bytes: Maximum bytes to read per file (default 256 KB).

    Returns:
        Formatted string containing file contents (or per-file error messages).
        Never raises — all errors are returned as error strings within the result.
    """
    canonical_root = os.path.realpath(repo_root)
    output_parts: list[str] = []

    for path in paths:
        # Reject absolute paths immediately (contract §Security Notes)
        if os.path.isabs(path):
            msg = f"[ERROR: path rejected — absolute paths are not allowed: {path!r}]"
            logger.warning("execute_read_files: absolute path rejected: %r", path)
            output_parts.append(msg)
            continue

        # Reject paths containing parent-traversal sequences (early rejection)
        if (
            ".." in pathlib.PurePosixPath(path).parts
            or ".." in pathlib.PureWindowsPath(path).parts
        ):
            msg = f"[ERROR: path rejected — parent traversal sequences are not allowed: {path!r}]"
            logger.warning("execute_read_files: traversal path rejected: %r", path)
            output_parts.append(msg)
            continue

        # Resolve the full path and verify it stays within the repo root jail
        candidate = os.path.realpath(os.path.join(canonical_root, path))
        if (
            not candidate.startswith(canonical_root + os.sep)
            and candidate != canonical_root
        ):
            msg = (
                f"[ERROR: path rejected — resolves outside repository root: {path!r} "
                f"-> {candidate!r}]"
            )
            logger.warning(
                "execute_read_files: path %r resolves outside repo root to %r",
                path,
                candidate,
            )
            output_parts.append(msg)
            continue

        # Attempt to read the file
        try:
            file_path = pathlib.Path(candidate)
            if not file_path.exists():
                output_parts.append(f"[ERROR: file not found: {path!r}]")
                continue

            if not file_path.is_file():
                output_parts.append(f"[ERROR: path is not a file: {path!r}]")
                continue

            raw_bytes = file_path.read_bytes()
            truncated = False
            if len(raw_bytes) > max_file_bytes:
                raw_bytes = raw_bytes[:max_file_bytes]
                truncated = True

            try:
                file_content = raw_bytes.decode("utf-8", errors="replace")
            except Exception:  # noqa: BLE001
                file_content = raw_bytes.decode("latin-1", errors="replace")

            entry = f"### {path}\n\n```\n{file_content}\n```"
            if truncated:
                entry += _TRUNCATION_MARKER_TEMPLATE.format(max_bytes=max_file_bytes)

            output_parts.append(entry)

        except OSError as exc:
            output_parts.append(f"[ERROR: could not read file {path!r}: {exc}]")

    if not output_parts:
        return "[No files returned — all paths were rejected or empty list provided]"

    return "\n\n".join(output_parts)
