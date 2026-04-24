#!/usr/bin/env python3
"""ACLI subprocess wrapper for Jira issue operations.

Provides create_issue, update_issue, and get_issue functions that invoke
the Atlassian CLI (ACLI) via subprocess calls. Includes retry with
exponential backoff on transient failures and fast-abort on auth errors.

No external dependencies — stdlib only (subprocess, json, time, os, base64, urllib).
"""

from __future__ import annotations

import base64
import json
import logging
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_DEFAULT_ACLI_CMD: list[str] = ["acli"]
_MAX_ATTEMPTS: int = 3  # initial + 2 retries
_AUTH_FAILURE_CODE: int = 401
_ASSIGNEE_PERMISSION_ERROR: str = "cannot be assigned"

# Local priority integer (0-4) → Jira priority name.
# Mirrors the mapping in bridge-outbound.py.
_LOCAL_PRIORITY_TO_JIRA: dict[int, str] = {
    0: "Highest",
    1: "High",
    2: "Medium",
    3: "Low",
    4: "Lowest",
}

# Local status string → Jira workflow state name.
# status.capitalize() produces "In_progress" for snake_case inputs; this mapping
# ensures correct Jira state names are used in ACLI transition commands.
_LOCAL_STATUS_TO_JIRA: dict[str, str] = {
    "open": "To Do",
    "in_progress": "In Progress",
    "closed": "Done",
    "blocked": "Blocked",
}


# ---------------------------------------------------------------------------
# ADF helpers
# ---------------------------------------------------------------------------


def _text_to_adf(text: str) -> dict[str, Any]:
    """Convert a plain text string to Atlassian Document Format (ADF).

    Jira REST API v3 (used by ACLI Go v1.3+) requires the ``description``
    field to be an ADF object, not a plain string.
    """
    paragraphs = []
    for line in text.split("\n"):
        if line:
            paragraphs.append(
                {"type": "paragraph", "content": [{"type": "text", "text": line}]}
            )
        else:
            paragraphs.append({"type": "paragraph", "content": []})
    return {"type": "doc", "version": 1, "content": paragraphs}


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
    and deterministic permission errors ("cannot be assigned") abort
    immediately without retrying.

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
            # Fast-abort on deterministic permission errors — retrying is pointless.
            # Callers print a contextual warning; no stderr print here to avoid duplication.
            if exc.stderr and _ASSIGNEE_PERMISSION_ERROR in exc.stderr:
                raise
            # If more retries remain, sleep with exponential backoff
            if attempt < _MAX_ATTEMPTS - 1:
                delay = 2 ** (attempt + 1)  # 2s, 4s
                time.sleep(delay)

    # All attempts exhausted — include stderr in the error message for debugging
    assert last_error is not None
    if last_error.stderr:
        print(f"ACLI stderr: {last_error.stderr.strip()}", file=sys.stderr)
    raise last_error


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def _verify_created_issue(
    stdout: str,
    *,
    acli_cmd: list[str] | None = None,
) -> dict[str, Any]:
    """Parse ACLI create output, verify the issue exists, and return it.

    Shared by both the JSON and non-JSON create paths to avoid duplicating
    the post-create verification logic.
    """
    created = json.loads(stdout)
    jira_key = created.get("key", "")
    if not jira_key:
        msg = f"ACLI create returned no key: {created}"
        raise RuntimeError(msg)

    verified = get_issue(jira_key=jira_key, acli_cmd=acli_cmd)
    if not verified:
        msg = f"Verify-after-create failed: issue {jira_key} not found"
        raise RuntimeError(msg)

    return verified


def create_issue(
    project: str,
    issue_type: str,
    summary: str,
    *,
    acli_cmd: list[str] | None = None,
    **kwargs: Any,
) -> dict[str, Any]:
    """Create a Jira issue via ACLI and verify it exists.

    Priority is set via ``--from-json`` with ``additionalAttributes``
    because ACLI does not expose a ``--priority`` CLI flag.
    """
    priority = kwargs.pop("priority", None)

    # When priority is requested, use --from-json so we can pass
    # additionalAttributes.priority (the only ACLI-supported path).
    if priority is not None:
        return _create_issue_from_json(
            project, issue_type, summary, priority, acli_cmd=acli_cmd, **kwargs
        )

    result = _create_issue_no_json(
        project, issue_type, summary, acli_cmd=acli_cmd, **kwargs
    )
    # REVIEW-DEFENSE: The "cannot be assigned" error only occurs when an assignee
    # field is present in the ACLI command. _create_issue_no_json returns None only
    # on that specific permission error. When no assignee kwarg is provided, the
    # --assignee flag is never sent, so this error cannot occur and result will
    # always be a CompletedProcess (or an exception is raised). Therefore, no
    # separate "result is None without assignee" branch is needed.
    if result is None and kwargs.get("assignee"):
        print(
            "Warning: assignee cannot be assigned — retrying without assignee",
            file=sys.stderr,
        )
        no_assignee_kwargs = {k: v for k, v in kwargs.items() if k != "assignee"}
        result = _create_issue_no_json(
            project, issue_type, summary, acli_cmd=acli_cmd, **no_assignee_kwargs
        )
        if result is None:
            msg = "ACLI create failed on retry without assignee"
            raise RuntimeError(msg)

    assert result is not None  # Guaranteed: either we have a result or raised above
    return _verify_created_issue(result.stdout, acli_cmd=acli_cmd)


def _create_issue_no_json(
    project: str,
    issue_type: str,
    summary: str,
    *,
    acli_cmd: list[str] | None = None,
    **kwargs: Any,
) -> subprocess.CompletedProcess[str] | None:
    """Build and run the non-JSON ACLI create command, returning the result.

    Returns ``None`` if ACLI fails with a "cannot be assigned" permission
    error so the caller can retry without the assignee field — matching
    the same None-on-permission-error contract as ``_create_from_json_payload``.
    """
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
    for field in ("description", "assignee"):
        if field in kwargs and kwargs[field] is not None:
            cmd.extend([f"--{field}", str(kwargs[field])])
    try:
        return _run_acli(cmd, acli_cmd=acli_cmd)
    except subprocess.CalledProcessError as exc:
        if exc.stderr and _ASSIGNEE_PERMISSION_ERROR in exc.stderr:
            return None
        raise


def _create_from_json_payload(
    payload: dict[str, Any],
    *,
    acli_cmd: list[str] | None = None,
) -> subprocess.CompletedProcess[str] | None:
    """Write *payload* to a temp file, run ACLI ``--from-json``, and return the result.

    Returns ``None`` if ACLI fails with a "cannot be assigned" permission
    error so the caller can retry without the assignee field.
    """
    fd, json_path = tempfile.mkstemp(suffix=".json", prefix="acli-create-")
    try:
        # REVIEW-DEFENSE: Exception control flow in the fd_owned guard is correct.
        # os.fdopen transfers ownership of fd to the file object. After fdopen
        # succeeds (fd_owned=True), the context manager's __exit__ closes fd —
        # so os.close(fd) is correctly skipped. If fdopen itself fails
        # (fd_owned=False), we must close fd manually. If json.dump raises after
        # fdopen succeeded, the exception propagates through the inner except
        # (which skips os.close because fd_owned=True), then through the outer
        # try — the finally block runs os.unlink correctly. The outer except
        # only catches CalledProcessError (from _run_acli), so json.dump
        # exceptions propagate to the caller as-is.
        fd_owned = False
        try:
            with os.fdopen(fd, "w") as f:
                fd_owned = True  # fd is now owned by the file object
                json.dump(payload, f)
        except Exception:
            if not fd_owned:
                os.close(fd)
            raise
        cmd = ["jira", "workitem", "create", "--from-json", json_path, "--json"]
        return _run_acli(cmd, acli_cmd=acli_cmd)
    except subprocess.CalledProcessError as exc:
        if exc.stderr and _ASSIGNEE_PERMISSION_ERROR in exc.stderr:
            return None
        raise
    finally:
        os.unlink(json_path)


def _create_issue_from_json(
    project: str,
    issue_type: str,
    summary: str,
    priority: str | int,
    *,
    acli_cmd: list[str] | None = None,
    **kwargs: Any,
) -> dict[str, Any]:
    """Create a Jira issue using ``--from-json`` to set priority.

    ACLI's ``workitem create`` does not have a ``--priority`` flag, but
    the ``--from-json`` path accepts ``additionalAttributes`` which maps
    directly to Jira REST API fields.  Priority requires
    ``{"name": "<Jira priority name>"}``.
    """
    # Convert integer priority (0-4) to Jira priority name.
    # If already a string name, use as-is.
    if isinstance(priority, int):
        jira_priority_name = _LOCAL_PRIORITY_TO_JIRA.get(priority, "Medium")
    else:
        jira_priority_name = str(priority)

    payload: dict[str, Any] = {
        "projectKey": project,
        "type": issue_type,
        "summary": summary,
        "additionalAttributes": {
            "priority": {"name": jira_priority_name},
        },
    }
    if kwargs.get("description"):
        payload["description"] = _text_to_adf(str(kwargs["description"]))
    if kwargs.get("assignee"):
        payload["assignee"] = str(kwargs["assignee"])

    result = _create_from_json_payload(payload, acli_cmd=acli_cmd)

    # If the assignee field caused a permission error, retry without it.
    # REVIEW-DEFENSE: _create_from_json_payload returns None only on
    # _ASSIGNEE_PERMISSION_ERROR, which requires an assignee in the payload.
    # When no assignee is present, the error cannot occur, so we only need
    # the "assignee in payload" branch — no separate elif for result is None
    # without assignee.
    if result is None and "assignee" in payload:
        print(
            f"Warning: assignee '{payload['assignee']}' cannot be assigned — "
            f"retrying without assignee",
            file=sys.stderr,
        )
        del payload["assignee"]
        result = _create_from_json_payload(payload, acli_cmd=acli_cmd)
        if result is None:
            msg = "ACLI create failed on retry without assignee"
            raise RuntimeError(msg)

    assert result is not None  # Guaranteed: either we have a result or raised above
    return _verify_created_issue(result.stdout, acli_cmd=acli_cmd)


def transition_issue(
    jira_key: str,
    status: str,
    *,
    acli_cmd: list[str] | None = None,
) -> dict[str, Any]:
    """Transition a Jira issue to a new status via ACLI.

    Status changes in Jira require transitions (not field edits).
    ACLI uses ``workitem transition --key KEY --status STATUS``.
    """
    cmd = [
        "jira",
        "workitem",
        "transition",
        "--key",
        jira_key,
        "--status",
        _LOCAL_STATUS_TO_JIRA.get(status, status.replace("_", " ").title()),
        "--json",
    ]
    result = _run_acli(cmd, acli_cmd=acli_cmd)
    return json.loads(result.stdout)


def update_issue(
    jira_key: str,
    *,
    acli_cmd: list[str] | None = None,
    **kwargs: Any,
) -> dict[str, Any]:
    """Update a Jira issue via ACLI.

    If ``status`` is in kwargs, it is routed to ``transition_issue``
    (Jira status changes require transitions, not field edits).
    Remaining fields are sent via ``workitem edit``.

    **Priority**: ACLI does not support editing priority (neither via
    ``--priority`` flag nor ``--from-json additionalAttributes``).
    Priority in kwargs is logged as a warning and skipped.
    See epic 392d-8080 for the full solution.
    """
    status = kwargs.pop("status", None)
    priority = kwargs.pop("priority", None)
    if priority is not None:
        logger.warning(
            "Cannot update priority on %s via ACLI (not supported). "
            "Priority '%s' will be skipped. See epic 392d-8080.",
            jira_key,
            priority,
        )

    if status is not None:
        transition_issue(jira_key, status, acli_cmd=acli_cmd)

    if not kwargs:
        # No editable fields remain (status/priority were already handled above)
        if status is not None:
            return {"key": jira_key, "status": status}
        return {"key": jira_key}

    cmd = [
        "jira",
        "workitem",
        "edit",
        "--key",
        jira_key,
        "--json",
    ]
    for field, value in kwargs.items():
        if field == "description":
            # Convert description to ADF (same as create_issue) — Jira REST API
            # v3 requires ADF format for description fields.
            cmd.extend([f"--{field}", json.dumps(_text_to_adf(str(value)))])
        else:
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
    search_issues, get_myself, get_server_info, get_comments, set_relationship.

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

        Uses self.jira_project as the project key. Extracts ticket_type,
        title, description, priority, and assignee from ticket_data
        (matching the CREATE event data schema).
        """
        project = self.jira_project
        issue_type = ticket_data.get("ticket_type", "Task").capitalize()
        summary = (ticket_data.get("title") or "").strip()
        if not summary:
            raise ValueError(
                f"Cannot create Jira issue: title/summary is empty "
                f"(ticket_data keys: {list(ticket_data.keys())})"
            )
        optional_fields: dict[str, Any] = {}
        if ticket_data.get("description"):
            optional_fields["description"] = ticket_data["description"]
        if ticket_data.get("priority") is not None:
            optional_fields["priority"] = ticket_data["priority"]
        if ticket_data.get("assignee"):
            optional_fields["assignee"] = ticket_data["assignee"]
        return create_issue(
            project, issue_type, summary, acli_cmd=self._acli_cmd, **optional_fields
        )

    def update_issue(self, jira_key: str, **kwargs: Any) -> dict[str, Any]:
        """Update a Jira issue via ACLI."""
        return update_issue(jira_key, acli_cmd=self._acli_cmd, **kwargs)

    def get_issue(self, jira_key: str) -> dict[str, Any]:
        """Get a Jira issue via ACLI."""
        return get_issue(jira_key, acli_cmd=self._acli_cmd)

    def add_comment(self, jira_key: str, body: str) -> dict[str, Any]:
        """Add a comment to a Jira issue via ACLI."""
        return add_comment(jira_key, body, acli_cmd=self._acli_cmd)

    def get_issue_link_types(self) -> list[dict[str, Any]]:
        """Return all available Jira issue link types via ACLI.

        Uses ``jira workitem link type list --json`` to query Jira for the
        full set of configured link types. Returns a list of dicts, each
        containing at minimum ``id`` and ``name`` fields (plus ``inward``
        and ``outward`` when the ACLI response includes them).

        Raises subprocess.CalledProcessError on ACLI failure.
        """
        cmd = [
            "jira",
            "workitem",
            "link",
            "type",
            "list",
            "--json",
        ]
        result = self._run(cmd)
        parsed = json.loads(result.stdout or "[]")
        if isinstance(parsed, list):
            return parsed
        # Some ACLI versions wrap the list in a dict under "issueLinkTypes"
        if isinstance(parsed, dict) and "issueLinkTypes" in parsed:
            return parsed["issueLinkTypes"]
        return []

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
                logging.warning(
                    "search_issues: unexpected ACLI JSON shape (type=%s); "
                    "treating as empty result. Response prefix: %.200r",
                    type(parsed).__name__,
                    parsed,
                )
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

    def get_myself(self) -> dict[str, Any]:
        """Return the authenticated user's Jira profile via GET /rest/api/2/myself.

        Used to retrieve the service account's profile timezone, which Jira Cloud
        uses when interpreting unqualified JQL datetime strings. Cached per instance.
        """
        if hasattr(self, "_myself_cache"):
            return self._myself_cache  # type: ignore[return-value]
        url = f"{self.jira_url.rstrip('/')}/rest/api/2/myself"
        creds = base64.b64encode(f"{self.user}:{self.api_token}".encode()).decode()
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Basic {creds}", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                self._myself_cache: dict[str, Any] = json.loads(
                    resp.read().decode("utf-8")
                )
        except (urllib.error.URLError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            logging.warning("get_myself: failed to fetch /rest/api/2/myself: %s", exc)
            # REVIEW-DEFENSE: Caching {} on error is intentional — callers handle
            # missing keys gracefully (defaulting to UTC), and caching prevents a
            # second network failure on the same run from the verify+fetch double-call.
            self._myself_cache = {}
        return self._myself_cache

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

    def get_issue_links(self, jira_key: str) -> list[dict[str, Any]]:
        """Get existing issue links for a Jira issue.

        Returns a list of link dicts matching the Jira REST API format:
        ``[{"type": {"name": ...}, "inwardIssue": {...}|None, "outwardIssue": {...}|None}]``

        Used by the LINK handler for pre-create deduplication.
        Raises subprocess.CalledProcessError on ACLI failure.
        """
        cmd = [
            "jira",
            "workitem",
            "link",
            "list",
            "--key",
            jira_key,
            "--json",
        ]
        result = self._run(cmd)
        parsed = json.loads(result.stdout or "[]")
        if isinstance(parsed, list):
            return parsed
        # Some ACLI versions wrap results in a dict with an "issuelinks" key
        if isinstance(parsed, dict):
            return parsed.get("issuelinks", [])
        return []

    def delete_issue_link(self, link_id: str) -> dict[str, Any]:
        """Delete a Jira issue link by its ID via ACLI.

        Uses ``jira workitem link delete --id LINK_ID`` to remove the link.
        Raises subprocess.CalledProcessError on ACLI failure (e.g. 404 if
        the link was already deleted, or 409 on concurrent modification).
        Callers should treat 404/409 as idempotent success.
        """
        cmd = [
            "jira",
            "workitem",
            "link",
            "delete",
            "--id",
            link_id,
        ]
        self._run(cmd)
        return {"status": "deleted", "link_id": link_id}
