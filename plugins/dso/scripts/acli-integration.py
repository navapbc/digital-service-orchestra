#!/usr/bin/env python3
"""ACLI subprocess wrapper for Jira issue operations.

Provides create_issue, update_issue, and get_issue functions that invoke
the Atlassian CLI (ACLI) via subprocess calls. Includes retry with
exponential backoff on transient failures and fast-abort on auth errors.

No external dependencies — stdlib only (subprocess, json, time, os).
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_DEFAULT_ACLI_CMD: list[str] = ["acli"]
_MAX_ATTEMPTS: int = 3  # initial + 2 retries
_AUTH_FAILURE_CODE: int = 401


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _build_env() -> dict[str, str]:
    """Build subprocess environment with ACLI JVM timezone flag."""
    env = os.environ.copy()
    java_opts = env.get("JAVA_TOOL_OPTIONS", "")
    tz_flag = "-Duser.timezone=UTC"
    if tz_flag not in java_opts:
        env["JAVA_TOOL_OPTIONS"] = f"{java_opts} {tz_flag}".strip()
    return env


def _run_acli(
    cmd: list[str],
    *,
    acli_cmd: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run an ACLI command with retry and exponential backoff.

    Retries up to 2 times (3 total attempts) on CalledProcessError,
    with backoff delays of 2s and 4s. Auth failures (exit code 401)
    abort immediately without retrying.

    Raises CalledProcessError if all attempts are exhausted.
    """
    base = acli_cmd if acli_cmd is not None else _DEFAULT_ACLI_CMD
    full_cmd = base + cmd
    env = _build_env()

    last_error: subprocess.CalledProcessError | None = None
    for attempt in range(_MAX_ATTEMPTS):
        try:
            result = subprocess.run(
                full_cmd,
                capture_output=True,
                text=True,
                check=True,
                env=env,
            )
            return result
        except subprocess.CalledProcessError as exc:
            last_error = exc
            # Fast-abort on auth failure
            if exc.returncode == _AUTH_FAILURE_CODE:
                raise
            # If more retries remain, sleep with exponential backoff
            if attempt < _MAX_ATTEMPTS - 1:
                delay = 2 ** (attempt + 1)  # 2s, 4s
                time.sleep(delay)

    # All attempts exhausted — re-raise the last error
    assert last_error is not None
    raise last_error


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def create_issue(
    project: str,
    issue_type: str,
    summary: str,
    *,
    acli_cmd: list[str] | None = None,
    **kwargs: Any,
) -> dict[str, Any]:
    """Create a Jira issue via ACLI and verify it exists.

    Args:
        project: Jira project key (e.g. "PROJ").
        issue_type: Issue type (e.g. "Task", "Story").
        summary: Issue summary text.
        acli_cmd: Override the ACLI base command (for testing).
        **kwargs: Additional fields (currently unused).

    Returns:
        dict with the created issue data (including 'key').

    Raises:
        subprocess.CalledProcessError: If ACLI fails after retries.
        RuntimeError: If verify-after-create fails (issue not found).
    """
    cmd = [
        "--action",
        "createIssue",
        "--project",
        project,
        "--type",
        issue_type,
        "--summary",
        summary,
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    created = json.loads(result.stdout)

    jira_key = created.get("key", "")
    if not jira_key:
        msg = f"ACLI create returned no key: {created}"
        raise RuntimeError(msg)

    # Verify-after-create: confirm the issue exists
    verified = get_issue(jira_key=jira_key, acli_cmd=acli_cmd)
    if not verified:
        msg = f"Verify-after-create failed: issue {jira_key} not found"
        raise RuntimeError(msg)

    return verified


def update_issue(
    jira_key: str,
    *,
    acli_cmd: list[str] | None = None,
    **kwargs: Any,
) -> dict[str, Any]:
    """Update a Jira issue via ACLI.

    Args:
        jira_key: Jira issue key (e.g. "PROJ-99").
        acli_cmd: Override the ACLI base command (for testing).
        **kwargs: Fields to update (e.g. status="In Progress").

    Returns:
        dict with the updated issue data.

    Raises:
        subprocess.CalledProcessError: If ACLI fails after retries.
    """
    cmd = [
        "--action",
        "updateIssue",
        "--issue",
        jira_key,
    ]
    for field, value in kwargs.items():
        cmd.extend([f"--{field}", str(value)])

    result = _run_acli(cmd, acli_cmd=acli_cmd)
    return json.loads(result.stdout)


def get_issue(
    jira_key: str,
    *,
    acli_cmd: list[str] | None = None,
) -> dict[str, Any]:
    """Get a Jira issue via ACLI.

    Args:
        jira_key: Jira issue key (e.g. "PROJ-7").
        acli_cmd: Override the ACLI base command (for testing).

    Returns:
        dict with issue data (key, summary, status, etc.).

    Raises:
        subprocess.CalledProcessError: If ACLI fails after retries.
    """
    cmd = [
        "--action",
        "getIssue",
        "--issue",
        jira_key,
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    return json.loads(result.stdout)


def add_comment(
    jira_key: str,
    body: str,
    *,
    acli_cmd: list[str] | None = None,
) -> dict[str, Any]:
    """Add a comment to a Jira issue via ACLI.

    Args:
        jira_key: Jira issue key (e.g. "PROJ-42").
        body: Comment body text (passed unchanged, may include markers).
        acli_cmd: Override the ACLI base command (for testing).

    Returns:
        dict with comment data (id, body, etc.).

    Raises:
        subprocess.CalledProcessError: If ACLI fails after retries.
    """
    cmd = [
        "--action",
        "addComment",
        "--issue",
        jira_key,
        "--comment",
        body,
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    return json.loads(result.stdout)


def get_comments(
    jira_key: str,
    *,
    acli_cmd: list[str] | None = None,
) -> list[dict[str, Any]]:
    """Get all comments on a Jira issue via ACLI.

    Args:
        jira_key: Jira issue key (e.g. "PROJ-55").
        acli_cmd: Override the ACLI base command (for testing).

    Returns:
        list of dicts, each with comment data (id, body, etc.).
        Returns empty list if no comments exist.

    Raises:
        subprocess.CalledProcessError: If ACLI fails after retries.
    """
    cmd = [
        "--action",
        "getComments",
        "--issue",
        jira_key,
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    # ACLI may output `null` for issues with no comments; `or []` ensures we always
    # return a list as documented in the docstring.
    return json.loads(result.stdout) or []
