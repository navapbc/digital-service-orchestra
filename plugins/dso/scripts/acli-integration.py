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
    """Build subprocess environment for ACLI."""
    return os.environ.copy()


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

    # All attempts exhausted — include stderr in the error message for debugging
    assert last_error is not None
    if last_error.stderr:
        import sys

        print(f"ACLI stderr: {last_error.stderr.strip()}", file=sys.stderr)
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
    """Create a Jira issue via ACLI and verify it exists."""
    cmd = [
        "jira",
        "workitem",
        "create",
        "--project",
        project,
        "--type",
        issue_type,
        "--summary",
        summary,
        "--json",
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    created = json.loads(result.stdout)

    jira_key = created.get("key", "")
    if not jira_key:
        msg = f"ACLI create returned no key: {created}"
        raise RuntimeError(msg)

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
    """Update a Jira issue via ACLI."""
    cmd = [
        "jira",
        "workitem",
        "edit",
        "--key",
        jira_key,
        "--json",
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
    """Get a Jira issue via ACLI."""
    cmd = [
        "jira",
        "workitem",
        "view",
        jira_key,
        "--json",
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    return json.loads(result.stdout)


def add_comment(
    jira_key: str,
    body: str,
    *,
    acli_cmd: list[str] | None = None,
) -> dict[str, Any]:
    """Add a comment to a Jira issue via ACLI."""
    cmd = [
        "jira",
        "workitem",
        "comment",
        "create",
        "--key",
        jira_key,
        "--body",
        body,
        "--json",
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    return json.loads(result.stdout)


def get_comments(
    jira_key: str,
    *,
    acli_cmd: list[str] | None = None,
) -> list[dict[str, Any]]:
    """Get all comments on a Jira issue via ACLI."""
    cmd = [
        "jira",
        "workitem",
        "comment",
        "list",
        "--key",
        jira_key,
        "--json",
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    return json.loads(result.stdout) or []


# ---------------------------------------------------------------------------
# AcliClient class — used by bridge-inbound.py and bridge-outbound.py
# ---------------------------------------------------------------------------


class AcliClient:
    """Client wrapping ACLI Go binary for Jira operations.

    Provides the method interface expected by bridge-inbound.py:
    search_issues, get_server_info, get_comments, set_relationship.

    Credentials are injected into the subprocess environment on each call
    so ACLI can authenticate without requiring prior ``acli auth`` setup.
    """

    def __init__(
        self,
        jira_url: str,
        user: str,
        api_token: str,
        *,
        jira_project: str = "",
        acli_cmd: list[str] | None = None,
    ) -> None:
        self.jira_url = jira_url
        self.user = user
        self.api_token = api_token
        self.jira_project = jira_project
        self._acli_cmd = acli_cmd

    def _run(self, cmd: list[str]) -> subprocess.CompletedProcess[str]:
        """Run an ACLI command.

        ACLI Go reads auth from its config file (set by ``acli auth login``).
        Credentials stored on self are available for callers that need them
        (e.g., direct REST calls), but are not injected into the subprocess
        environment — ACLI does not read env vars for auth.
        """
        return _run_acli(cmd, acli_cmd=self._acli_cmd)

    # --- Outbound bridge methods ---

    def create_issue(self, ticket_data: dict[str, Any]) -> dict[str, Any]:
        """Create a Jira issue from a ticket data dict.

        Uses self.jira_project as the project key. Extracts ticket_type and
        title from ticket_data (matching the CREATE event data schema).
        """
        project = self.jira_project
        issue_type = ticket_data.get("ticket_type", "Task")
        summary = ticket_data.get("title", "")
        return create_issue(project, issue_type, summary, acli_cmd=self._acli_cmd)

    def update_issue(self, jira_key: str, **kwargs: Any) -> dict[str, Any]:
        """Update a Jira issue via ACLI."""
        return update_issue(jira_key, acli_cmd=self._acli_cmd, **kwargs)

    def get_issue(self, jira_key: str) -> dict[str, Any]:
        """Get a Jira issue via ACLI."""
        return get_issue(jira_key, acli_cmd=self._acli_cmd)

    def add_comment(self, jira_key: str, body: str) -> dict[str, Any]:
        """Add a comment to a Jira issue via ACLI."""
        return add_comment(jira_key, body, acli_cmd=self._acli_cmd)

    def search_issues(
        self,
        jql: str,
        start_at: int = 0,
        max_results: int = 50,
    ) -> list[dict[str, Any]]:
        """Search Jira issues via JQL, returning a page slice.

        ACLI Go has no offset flag, so --paginate fetches all results in one
        call. Results are cached per-JQL to avoid redundant fetches when the
        caller paginates. Returns a slice of ``[start_at:start_at+max_results]``
        to satisfy the bridge's pagination loop contract.
        """
        # Cache the full result set for this JQL to avoid re-fetching
        if not hasattr(self, "_search_cache"):
            self._search_cache: dict[str, list[dict[str, Any]]] = {}

        if jql not in self._search_cache:
            cmd = [
                "jira",
                "workitem",
                "search",
                "--jql",
                jql,
                "--paginate",
                "--json",
            ]
            result = self._run(cmd)
            parsed = json.loads(result.stdout)
            if isinstance(parsed, list):
                all_issues = parsed
            elif isinstance(parsed, dict) and "issues" in parsed:
                all_issues = parsed["issues"]
            else:
                all_issues = []
            self._search_cache[jql] = all_issues

        all_issues = self._search_cache[jql]
        return all_issues[start_at : start_at + max_results]

    def get_server_info(self) -> dict[str, Any]:
        """Get Jira server info for timezone verification.

        Jira Cloud always stores timestamps in UTC. The legacy Java ACLI
        needed a JVM timezone flag to avoid locale-dependent serialization;
        the Go ACLI has no such issue. Connectivity is already verified by
        the workflow's ``acli auth login`` step — a redundant API call here
        would add latency and a failure mode with no diagnostic value.
        """
        return {"timeZone": "UTC", "serverTitle": "Jira Cloud"}

    def get_comments(self, jira_key: str) -> list[dict[str, Any]]:
        """Get all comments on a Jira issue."""
        cmd = [
            "jira",
            "workitem",
            "comment",
            "list",
            "--key",
            jira_key,
            "--json",
        ]
        result = self._run(cmd)
        return json.loads(result.stdout) or []

    def set_relationship(
        self,
        from_key: str,
        to_key: str,
        link_type: str = "Blocks",
    ) -> dict[str, Any]:
        """Create a link between two Jira issues.

        Raises subprocess.CalledProcessError on ACLI failure.
        """
        cmd = [
            "jira",
            "workitem",
            "link",
            "create",
            "--out",
            from_key,
            "--in",
            to_key,
            "--type",
            link_type,
        ]
        self._run(cmd)  # raises on failure — no silent swallowing
        return {"status": "created", "from": from_key, "to": to_key}
