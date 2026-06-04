"""Local binding store for Jira bidirectional sync.

Maps local ticket IDs ↔ Jira issue keys.  Persisted as JSON at
`.tickets-tracker/.bridge_state/bindings.json` on the tickets branch.  # tickets-boundary-ok

Write-ahead protocol
--------------------
1. bind_pending(local_id)          — mark outbound create in-flight
2. Jira client.create_issue(...)   — obtain DIG-NNNN
3. Jira client.add_label / set_entity_property — plant dso-id marker
4. bind_confirm(local_id, jira_key) — finalise binding
5. save()                          — atomic persist

Recovery (next pass startup): recover_pending_bindings(client) searches
Jira for the dso-id label and either confirms or unbinds each pending
entry.
"""

from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


_EMPTY_STORE: dict[str, Any] = {
    "version": 1,
    "bindings": {},
    "reverse": {},
}


class BindingStore:
    """Bidirectional local-id ↔ jira-key binding store.

    All mutations are in-memory until ``save()`` is called.
    ``save()`` uses tempfile + ``os.replace`` for atomic writes.
    """

    def __init__(self, tracker_dir: Path) -> None:
        self._path = tracker_dir / ".bridge_state" / "bindings.json"
        self._data = self._load()

    # -- persistence -------------------------------------------------------

    def _load(self) -> dict[str, Any]:
        if self._path.exists():
            try:
                with open(self._path, "r", encoding="utf-8") as f:
                    return json.load(f)
            except (json.JSONDecodeError, ValueError, OSError) as exc:
                # Fail CLOSED: corrupt or conflict-marked bindings.json must
                # never silently degrade to empty bindings.  An empty store
                # treats every local ticket as unbound → emits CREATE mutations
                # for all of them on the next pass → mass duplicate Jira issues.
                #
                # Recovery hint: resolve the git merge conflict in the file or
                # restore it from the most recent commit on the tickets branch.
                raise ValueError(
                    f"bindings.json is corrupt or contains git conflict markers "
                    f"and cannot be parsed — aborting reconcile pass to prevent "
                    f"duplicate Jira mutations. File: {self._path}. "  # tickets-boundary-ok
                    f"Original error: {exc}. "
                    f"Recovery: resolve the merge conflict or restore the file "  # tickets-boundary-ok
                    f"from the tickets branch with: "
                    f"git show tickets:.tickets-tracker/.bridge_state/bindings.json"  # tickets-boundary-ok
                ) from exc
        return json.loads(json.dumps(_EMPTY_STORE))  # deep copy

    def save(self) -> None:
        """Atomic write via tempfile + os.replace."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(
            dir=str(self._path.parent),
            prefix="bindings_",
            suffix=".tmp",
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(self._data, f, indent=2, sort_keys=True)
                f.write("\n")
            os.replace(tmp, str(self._path))
        except BaseException:
            # Clean up temp file on any failure
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    # -- queries -----------------------------------------------------------

    def get_jira_key(self, local_id: str) -> str | None:
        entry = self._data["bindings"].get(local_id)
        if entry is None:
            return None
        return entry.get("jira_key")

    def get_local_id(self, jira_key: str) -> str | None:
        return self._data["reverse"].get(jira_key)

    def is_bound(self, local_id: str) -> bool:
        return local_id in self._data["bindings"]

    def is_pending(self, local_id: str) -> bool:
        entry = self._data["bindings"].get(local_id)
        return entry is not None and entry.get("state") == "pending"

    def all_bindings(self) -> dict[str, dict]:
        return dict(self._data["bindings"])

    def pending_bindings(self) -> list[str]:
        return [
            lid
            for lid, entry in self._data["bindings"].items()
            if entry.get("state") == "pending"
        ]

    def confirmed_count(self) -> int:
        return sum(
            1
            for entry in self._data["bindings"].values()
            if entry.get("state") == "confirmed"
        )

    # -- mutations ---------------------------------------------------------

    def bind_pending(self, local_id: str) -> None:
        """Mark a local ticket as pending outbound creation."""
        now = _now_iso()
        self._data["bindings"][local_id] = {
            "jira_key": None,
            "state": "pending",
            "created_at": now,
            "updated_at": now,
        }

    def bind_confirm(self, local_id: str, jira_key: str) -> None:
        """Confirm binding after Jira issue creation succeeds."""
        now = _now_iso()
        entry = self._data["bindings"].get(local_id)
        if entry is None:
            # Direct confirm without prior pending — allowed for recovery
            entry = {"created_at": now}
            self._data["bindings"][local_id] = entry
        entry["jira_key"] = jira_key
        entry["state"] = "confirmed"
        entry["updated_at"] = now
        # Maintain reverse index
        self._data["reverse"][jira_key] = local_id

    def unbind(self, local_id: str) -> None:
        """Remove binding (for cleanup/rollback)."""
        entry = self._data["bindings"].pop(local_id, None)
        if entry is not None and entry.get("jira_key"):
            self._data["reverse"].pop(entry["jira_key"], None)

    # -- recovery ----------------------------------------------------------

    def recover_pending_bindings(self, client: Any) -> int:
        """Scan for pending bindings and attempt to recover.

        For each pending binding:
        1. Search Jira for dso-id-{local_id} label
        2. If found → confirm binding with discovered jira_key
        3. If not found → unbind (the create never reached Jira)

        Returns count of recovered bindings.
        """
        recovered = 0
        for local_id in list(self.pending_bindings()):
            label = f"dso-id-{local_id}"
            results = client.search_issues(f'labels = "{label}"')
            if results:
                jira_key = results[0]["key"]
                self.bind_confirm(local_id, jira_key)
            else:
                self.unbind(local_id)
            recovered += 1
        return recovered


def load_binding_store(repo_root: Path) -> BindingStore:
    """Entry point for the reconciler orchestrator — call at pass start."""
    tracker_dir = repo_root / ".tickets-tracker"  # tickets-boundary-ok
    return BindingStore(tracker_dir)
