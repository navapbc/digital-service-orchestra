"""CI guard: no retired token references in .github/workflows/ YAML files.

Retired tokens:
  - bridge_state   (old edge-triggered bridge state key)
  - prev_snapshot  (prior snapshot reference pattern)
  - mapping.json   (legacy mapping file reference)

Two orthogonal assertions:
  1. test_scanner_detects_planted_violation — self-check / mechanics proof.
     Plants 'bridge_state' into a fake .yml file under tmp_path, runs the
     scanner against tmp_path, asserts ≥1 hit is returned.  Proves the
     matcher itself is operational; this is NOT a tautology.

  2. test_real_workflows_have_zero_hits — production scan.
     Explicitly pins the scan root to repo_root / '.github' / 'workflows'.
     Asserts 0 hits for all three retired tokens across the real workflow tree.
     The absolute-path pin is mechanically auditable:
       grep -qE 'repo_root.*workflows|\\.github/workflows' <this file>
     must match — ensuring a mis-pointed scan cannot silently pass.
"""

from __future__ import annotations

from pathlib import Path
from typing import NamedTuple

import pytest


# ---------------------------------------------------------------------------
# Scan helper
# ---------------------------------------------------------------------------

RETIRED_TOKENS: tuple[str, ...] = ("bridge_state", "prev_snapshot", "mapping.json")


class _Hit(NamedTuple):
    file: Path
    line_number: int
    token: str
    line_text: str


def scan_workflows_for_retired_tokens(scan_root: Path) -> list[_Hit]:
    """Return every (file, line_number, token, line_text) where a retired token appears.

    Parameters
    ----------
    scan_root:
        Absolute path to the directory tree to scan.  All ``*.yml`` files
        found recursively are examined.

    Returns
    -------
    list[_Hit]
        Empty list when the tree is clean; non-empty when violations exist.
    """
    hits: list[_Hit] = []
    for yml_file in sorted(scan_root.rglob("*.yml")):
        try:
            text = yml_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, raw_line in enumerate(text.splitlines(), start=1):
            for token in RETIRED_TOKENS:
                if token in raw_line:
                    hits.append(_Hit(yml_file, lineno, token, raw_line.rstrip()))
    return hits


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_scanner_detects_planted_violation(tmp_path: Path) -> None:
    """Self-check: scanner finds a deliberately planted retired token.

    Creates a synthetic ``.github/workflows/`` tree under ``tmp_path``,
    writes a ``fake-workflow.yml`` that contains the string ``bridge_state``,
    then asserts the scanner returns at least one hit.

    This test proves that the *matcher mechanics* are operational — it is not
    a tautology because it exercises the actual code path on real file I/O,
    not a mock.
    """
    fake_workflows = tmp_path / ".github" / "workflows"
    fake_workflows.mkdir(parents=True)
    fake_yml = fake_workflows / "fake-workflow.yml"
    fake_yml.write_text(
        "name: legacy-bridge\n"
        "on: push\n"
        "jobs:\n"
        "  sync:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps:\n"
        "      - name: Read bridge_state from bucket\n"
        "        run: echo reading bridge_state\n",
        encoding="utf-8",
    )

    hits = scan_workflows_for_retired_tokens(fake_workflows)

    assert len(hits) >= 1, (
        "Expected >=1 hit for planted 'bridge_state' token but scanner returned empty. "
        "Scan-root was: " + str(fake_workflows)
    )
    tokens_found = {h.token for h in hits}
    assert "bridge_state" in tokens_found, (
        f"Expected 'bridge_state' in detected tokens; got {tokens_found}"
    )


def test_real_workflows_have_zero_hits() -> None:
    """Production scan: real .github/workflows/ tree must contain no retired tokens.

    The scan root is EXPLICITLY pinned to::

        repo_root / '.github' / 'workflows'

    This absolute-path pin is mechanically auditable — the following grep
    must match this file::

        grep -qE 'repo_root.*workflows|\\.github/workflows' <this file>

    Scans all three retired tokens:
      - bridge_state
      - prev_snapshot
      - mapping.json
    """
    repo_root = Path(__file__).resolve().parents[3]  # tests/unit/dso_reconciler -> repo root
    workflows_path = repo_root / ".github" / "workflows"

    assert workflows_path.is_dir(), (
        f"Expected .github/workflows/ to exist at {workflows_path}. "
        "If the repository structure changed, update the parent traversal depth."
    )

    hits = scan_workflows_for_retired_tokens(workflows_path)

    if hits:
        details = "\n".join(
            f"  {h.file.relative_to(repo_root)}:{h.line_number}: [{h.token}] {h.line_text}"
            for h in hits
        )
        pytest.fail(
            f"Found {len(hits)} retired-token reference(s) in "
            f"{workflows_path.relative_to(repo_root)}:\n{details}\n\n"
            "Remove all references to retired bridge tokens "
            "(bridge_state, prev_snapshot, mapping.json) from workflow files."
        )
