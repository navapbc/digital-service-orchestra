#!/usr/bin/env python3
"""Forward-compatibility probe: exercises 4 identity-critical Jira operations on a throwaway issue."""

from __future__ import annotations

import importlib.util
import os
import uuid
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class StepResult:
    name: str
    ok: bool
    message: str
    details: dict = field(default_factory=dict)


def _load_acli_client():
    """Load AcliClient from acli-integration.py in the scripts directory."""
    here = Path(__file__).parent
    # Navigate to the scripts directory (one level up from dso_reconciler/)
    acli_path = here.parent / "acli-integration.py"
    spec = importlib.util.spec_from_file_location("acli_integration", acli_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.AcliClient


def run() -> StepResult:
    """Exercise 4 identity-critical Jira sub-operations on a throwaway issue."""
    jira_url = os.environ.get("JIRA_URL", "")
    jira_user = os.environ.get("JIRA_USER", "")
    jira_token = os.environ.get("JIRA_API_TOKEN", "")

    if not (jira_url and jira_user and jira_token):
        return StepResult(
            name="forward_compat_probe",
            ok=False,
            message="missing Jira credentials (JIRA_URL, JIRA_USER, JIRA_API_TOKEN)",
        )

    probe_uuid = str(uuid.uuid4())
    label = f"dso-id:{probe_uuid}"
    issue_key = None
    sub_ops: list[dict] = []

    try:
        AcliClient = _load_acli_client()
        client = AcliClient(
            jira_url=jira_url,
            user=jira_user,
            api_token=jira_token,
            jira_project="DIG",
        )

        # Create throwaway issue
        result = client.create_issue({
            "title": f"DSO forward-compat probe {probe_uuid}",
            "ticket_type": "task",
        })
        issue_key = result.get("key") or result.get("id")
        if not issue_key:
            return StepResult(
                name="forward_compat_probe",
                ok=False,
                message=f"create_issue returned no key/id: {result!r}",
                details={"sub_operations": sub_ops},
            )

        # Sub-op 1: label_write (raw PUT — issue updates take {"update": ...}, not {"value": ...})
        try:
            client._direct_rest_put_raw(
                f"/rest/api/3/issue/{issue_key}",
                {"update": {"labels": [{"add": label}]}},
            )
            sub_ops.append({"op": "label_write", "ok": True})
        except Exception as exc:
            sub_ops.append({"op": "label_write", "ok": False, "error": str(exc)})
            return StepResult(
                name="forward_compat_probe",
                ok=False,
                message=f"FAIL label_write: {exc}",
                details={"sub_operations": sub_ops},
            )

        # Sub-op 2: property_write
        try:
            client.set_issue_property(issue_key, "dso_local_id", probe_uuid)
            sub_ops.append({"op": "property_write", "ok": True})
        except Exception as exc:
            sub_ops.append({"op": "property_write", "ok": False, "error": str(exc)})
            return StepResult(
                name="forward_compat_probe",
                ok=False,
                message=f"FAIL property_write: {exc}",
                details={"sub_operations": sub_ops},
            )

        # Sub-op 3: jql_search
        try:
            results = client.search_issues(f'labels="{label}"')
            found = any(r.get("key") == issue_key for r in results)
            sub_ops.append({"op": "jql_search", "ok": found})
            if not found:
                return StepResult(
                    name="forward_compat_probe",
                    ok=False,
                    message="FAIL jql_search: issue key not found in label search results",
                    details={"sub_operations": sub_ops},
                )
        except Exception as exc:
            sub_ops.append({"op": "jql_search", "ok": False, "error": str(exc)})
            return StepResult(
                name="forward_compat_probe",
                ok=False,
                message=f"FAIL jql_search: {exc}",
                details={"sub_operations": sub_ops},
            )

        # Sub-op 4: property_rest_read
        try:
            value = client.get_issue_property(issue_key, "dso_local_id")
            match = value == probe_uuid
            sub_ops.append({"op": "property_rest_read", "ok": match})
            if not match:
                return StepResult(
                    name="forward_compat_probe",
                    ok=False,
                    message=f"FAIL property_rest_read: expected {probe_uuid!r}, got {value!r}",
                    details={"sub_operations": sub_ops},
                )
        except Exception as exc:
            sub_ops.append({"op": "property_rest_read", "ok": False, "error": str(exc)})
            return StepResult(
                name="forward_compat_probe",
                ok=False,
                message=f"FAIL property_rest_read: {exc}",
                details={"sub_operations": sub_ops},
            )

        return StepResult(
            name="forward_compat_probe",
            ok=True,
            message="all 4 sub-operations passed",
            details={"sub_operations": sub_ops},
        )

    finally:
        if issue_key:
            try:
                AcliClient = _load_acli_client()
                client = AcliClient(
                    jira_url=jira_url,
                    user=jira_user,
                    api_token=jira_token,
                )
                client.delete_issue(issue_key)
            except Exception:
                pass
