#!/usr/bin/env python3
"""DSO Jira capability probe — six-step round-trip verification.

Verifies that all Jira operations required by the DSO bridge are functional:
create, label, property-write, JQL-search, property-read, delete.

Exit codes:
  0 — all six steps passed
  1 — one or more steps failed (but credentials were present)
  2 — missing credentials (JIRA_URL, JIRA_USER, or JIRA_API_TOKEN)

Environment variables:
  JIRA_URL        — Base URL of the Jira instance
  JIRA_USER       — Jira username (email for Jira Cloud)
  JIRA_API_TOKEN  — Jira API token
"""

from __future__ import annotations

import importlib.util
import os
import sys
import time
import uuid
from pathlib import Path

# ---------------------------------------------------------------------------
# Load acli-integration from the same directory (filename has hyphens)
# ---------------------------------------------------------------------------

_HERE = Path(__file__).parent
_acli_spec = importlib.util.spec_from_file_location(
    "acli_integration",
    _HERE / "acli-integration.py",
)
_acli_mod = importlib.util.module_from_spec(_acli_spec)
_acli_spec.loader.exec_module(_acli_mod)
AcliClient = _acli_mod.AcliClient

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_JQL_RETRY_COUNT = 3
_JQL_RETRY_SLEEP = 2  # seconds


# ---------------------------------------------------------------------------
# Main probe
# ---------------------------------------------------------------------------


def main() -> None:
    jira_url = os.environ.get("JIRA_URL", "")
    jira_user = os.environ.get("JIRA_USER", "")
    jira_api_token = os.environ.get("JIRA_API_TOKEN", "")

    if not jira_url or not jira_user or not jira_api_token:
        print("PROBE_FAIL reason=missing_credentials")
        sys.exit(2)

    probe_uuid = str(uuid.uuid4())
    label = f"dso-id:{probe_uuid}"

    client = AcliClient(
        jira_url=jira_url,
        user=jira_user,
        api_token=jira_api_token,
    )

    issue_key: str | None = None
    failed = False

    try:
        # STEP 1: Create issue
        issue_key = client.create_issue(
            project="DIG",
            summary=f"DSO capability probe {probe_uuid}",
            issuetype="Task",
        )
        print("PROBE_PASS step=STEP_CREATE")

        # STEP 2: Add label
        client._direct_rest_put(
            f"/rest/api/3/issue/{issue_key}",
            {"update": {"labels": [{"add": label}]}},
        )
        print("PROBE_PASS step=STEP_LABEL")

        # STEP 3: Write issue property
        client.set_issue_property(issue_key, "dso_local_id", probe_uuid)
        print("PROBE_PASS step=STEP_PROPERTY_WRITE")

        # STEP 4: JQL search with retry
        jql = f'labels="{label}"'
        results: list = []
        for _attempt in range(_JQL_RETRY_COUNT):
            results = client.search_issues(jql)
            if results:
                break
            if _attempt < _JQL_RETRY_COUNT - 1:
                time.sleep(_JQL_RETRY_SLEEP)

        if not results:
            print("PROBE_FAIL step=STEP_JQL_SEARCH reason=no_results_after_retry")
            failed = True
        else:
            print("PROBE_PASS step=STEP_JQL_SEARCH")

        # STEP 5: Read property back and verify
        read_value = client.get_issue_property(issue_key, "dso_local_id")
        if read_value != probe_uuid:
            print(
                f"PROBE_FAIL step=STEP_PROPERTY_READ "
                f"reason=value_mismatch expected={probe_uuid} got={read_value}"
            )
            failed = True
        else:
            print("PROBE_PASS step=STEP_PROPERTY_READ")

    except Exception as exc:  # noqa: BLE001
        print(f"PROBE_FAIL reason=exception detail={exc}")
        failed = True

    finally:
        # STEP 6: Delete (best-effort cleanup — always runs)
        if issue_key is not None:
            try:
                client.delete_issue(issue_key)
                print("PROBE_PASS step=STEP_DELETE")
            except Exception as exc:  # noqa: BLE001
                print(f"PROBE_FAIL step=STEP_DELETE reason=exception detail={exc}")

    sys.exit(1 if failed else 0)


main()
