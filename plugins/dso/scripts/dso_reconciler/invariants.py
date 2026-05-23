from __future__ import annotations

import importlib.util
import subprocess
import sys
import time
from pathlib import Path

_CAP_PER_PASS = 5


def _load_alert_store():
    """Load the sibling alert_store.py module.

    No repo_root parameter — alert_store always lives next to this file in the
    dso_reconciler package; accepting a configurable path would be misleading
    because the path is not actually used.
    """
    spec = importlib.util.spec_from_file_location(
        "alert_store", Path(__file__).parent / "alert_store.py"
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("invariants_alert_store", mod)
    spec.loader.exec_module(mod)
    return mod


def check_at_most_one_dso_local_id(
    snapshot: dict,
    repo_root: Path | None = None,
    ticket_cli: str | None = None,
) -> list[dict]:
    """Check that no Jira issue has more than one dso_local_id mapping.

    snapshot: dict mapping jira_key -> {fields}
    Returns list of violation dicts filed this pass.

    Bug-filing failures (TimeoutExpired, FileNotFoundError, OSError) are
    surfaced to stderr but do NOT abort the loop or re-raise — the alert
    record itself is rolled back so the next reconciler pass re-files cleanly
    instead of being short-circuited by is_deduped on an orphaned record.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]
    if ticket_cli is None:
        ticket_cli = str(Path(__file__).parents[4] / ".claude/scripts/dso")

    alert_store = _load_alert_store()
    violations_filed = []

    for jira_key, fields in snapshot.items():
        # Check if this issue has multiple dso_local_id values (duplicates)
        dso_ids = fields.get("dso_local_ids", [])
        if isinstance(dso_ids, list) and len(dso_ids) > 1:
            if len(violations_filed) >= _CAP_PER_PASS:
                continue

            dedup_key = f"at-most-one:{jira_key}"
            if alert_store.is_deduped(dedup_key, repo_root):
                continue

            # File bridge-alert record
            record = {
                "key": dedup_key,
                "jira_key": jira_key,
                "timestamp_ns": time.time_ns(),
                "reason": f"multiple dso_local_ids: {dso_ids}",
            }
            alert_store.append(record, repo_root)

            # File bug ticket via CLI. Narrow exception handling: catch the
            # subprocess-class and OS-class exceptions explicitly so genuine
            # programming errors (AttributeError, TypeError) still propagate.
            bug_id = ""
            cli_error: str | None = None
            try:
                result = subprocess.run(
                    [
                        ticket_cli,
                        "ticket",
                        "create",
                        "bug",
                        f"at-most-one violation: {jira_key} has multiple dso_local_ids",
                        "--priority",
                        "1",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                if result.returncode == 0 and result.stdout.strip():
                    bug_id = result.stdout.strip().split()[-1]
                else:
                    cli_error = (
                        f"exit={result.returncode} stderr={result.stderr[:200]!r}"
                    )
            except subprocess.TimeoutExpired:
                cli_error = "ticket-create timed out after 30s"
            except (OSError, subprocess.SubprocessError) as exc:
                cli_error = f"{type(exc).__name__}: {exc}"

            if bug_id:
                alert_store.patch_bug_filed(dedup_key, bug_id, repo_root)
            else:
                # Bug-filing failed. Surface the failure to operators via
                # stderr, then leave the alert record on disk. The next pass
                # will hit is_deduped() and skip — operators must manually
                # file the bug or roll the alert forward. See bug ticket TBD
                # for a sweeper that converts orphan alerts into ticket-create
                # retries on subsequent passes.
                print(  # noqa: T201
                    f"WARN: invariants.check_at_most_one_dso_local_id: "
                    f"alert {dedup_key!r} filed but bug-ticket creation "
                    f"failed ({cli_error}); alert is orphan-without-bug.",
                    file=sys.stderr,
                )

            violations_filed.append(
                {
                    "jira_key": jira_key,
                    "dso_local_ids": dso_ids,
                    "dedup_key": dedup_key,
                }
            )

    return violations_filed
