#!/usr/bin/env bash
# check-coordination-pass-immutability.sh — Enforce hard-constraint immutability
# across the coordination-pass diff of a gov-copy artifact.
#
# Usage:
#   bash check-coordination-pass-immutability.sh <first-pass.yaml> <second-pass.yaml>
#
# Behaviour:
#   For each item in the first-pass artifact whose rationale.rule_ids cites at
#   least one canon entry with hard_constraint=true, the corresponding item in
#   the second-pass artifact MUST have IDENTICAL values.label, values.hint, and
#   values.errors.  Any mutation on a hard-constraint item causes a non-zero
#   exit with a diagnostic naming the offending item stable_id and canon rule_id.
#
#   Items whose rule_ids cite only hard_constraint=false canon entries (or no
#   canon entries at all) are free to change — the script ignores them.
#
# Canon source:
#   ${CLAUDE_PLUGIN_ROOT}/data/ui-reference/canon/*.yaml
#   Each canon YAML has a top-level `hard_constraint: true/false` field and an
#   `id:` field.  A rule_id in an artifact item cites a canon entry when the
#   rule_id starts with "<canon-id>." (e.g. "uswds-forms.error-specific" → id
#   "uswds-forms").
#
# Exit codes:
#   0   All hard-constraint items are unchanged in the second pass.
#   1   One or more hard-constraint items were mutated (diagnostic on stderr).
#   2   Usage or dependency error.
#
# References: story c5ef-a8ba-e889-4c88, task 4a87-6476-3235-4c70.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
  echo "ERROR: Usage: $(basename "$0") <first-pass.yaml> <second-pass.yaml>" >&2
  exit 2
fi

FIRST_PASS="$1"
SECOND_PASS="$2"

for f in "$FIRST_PASS" "$SECOND_PASS"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: File not found: $f" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not found in PATH" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Locate canon directory
# ---------------------------------------------------------------------------
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Canonicalise: scripts/ → parent (plugin root)
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
CANON_DIR="$_PLUGIN_ROOT/data/ui-reference/canon"

if [[ ! -d "$CANON_DIR" ]]; then
  echo "ERROR: Canon directory not found: $CANON_DIR" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Inline Python diff-checker
# ---------------------------------------------------------------------------
python3 - "$FIRST_PASS" "$SECOND_PASS" "$CANON_DIR" <<'PYEOF'
from __future__ import annotations

import sys
import os
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(2)


def load_yaml(path: Path) -> Any:
    with path.open() as fh:
        return yaml.safe_load(fh)


def build_hard_constraint_set(canon_dir: Path) -> set[str]:
    """Return the set of canon corpus `id` values whose hard_constraint == true."""
    hard_ids: set[str] = set()
    for canon_file in sorted(canon_dir.glob("*.yaml")):
        if canon_file.name.startswith("_"):
            # Skip meta files like _overview.yaml
            continue
        try:
            doc = load_yaml(canon_file)
        except Exception as exc:
            # Fail CLOSED: a parse failure could hide a hard_constraint entry,
            # which would let a coordination-pass mutation slip through against
            # an immutable rule. We refuse to proceed rather than warn-and-continue.
            print(
                f"ERROR: Could not parse canon file {canon_file.name}: {exc}",
                file=sys.stderr,
            )
            print(
                "ERROR: Refusing to enforce immutability with a partial canon corpus "
                "(would risk false-pass on hard-constraint mutations).",
                file=sys.stderr,
            )
            sys.exit(2)
        if not isinstance(doc, dict):
            continue
        canon_id = doc.get("id", "")
        hc = doc.get("hard_constraint", False)
        if hc is True and canon_id:
            hard_ids.add(canon_id)
    if not hard_ids:
        # Fail CLOSED on an empty hard-constraint set. If a real corpus has
        # zero hard_constraint:true entries, the project should not be running
        # this script at all — the empty case is far more likely caused by a
        # mis-located CANON_DIR or systemic schema breakage than by intent.
        print(
            "ERROR: No hard-constraint canon entries found in CANON_DIR. "
            "Refusing to silently approve all mutations.",
            file=sys.stderr,
        )
        sys.exit(2)
    return hard_ids


def rule_ids_cite_hard_constraint(rule_ids: list[str], hard_ids: set[str]) -> list[str]:
    """
    Return the subset of rule_ids that reference a hard-constraint canon entry.

    A rule_id cites a canon entry when the rule_id starts with "<canon-id>."
    (e.g. "uswds-forms.error-specific" → canon id "uswds-forms").
    Plain equality is also checked as a fallback (rule_id == canon_id).
    """
    matching: list[str] = []
    for rid in rule_ids:
        for hid in hard_ids:
            if rid == hid or rid.startswith(hid + "."):
                matching.append(rid)
                break
    return matching


def values_equal(v1: Any, v2: Any) -> bool:
    """Deep equality check for the values block."""
    return v1 == v2


def main() -> None:
    first_pass_path = Path(sys.argv[1])
    second_pass_path = Path(sys.argv[2])
    canon_dir = Path(sys.argv[3])

    # Load artifacts
    first_doc = load_yaml(first_pass_path)
    second_doc = load_yaml(second_pass_path)

    if not isinstance(first_doc, dict) or "items" not in first_doc:
        print(
            "ERROR: First-pass artifact is not a valid gov-copy artifact (missing 'items' key)",
            file=sys.stderr,
        )
        sys.exit(2)

    if not isinstance(second_doc, dict) or "items" not in second_doc:
        print(
            "ERROR: Second-pass artifact is not a valid gov-copy artifact (missing 'items' key)",
            file=sys.stderr,
        )
        sys.exit(2)

    # Build index of second-pass items by id
    second_items: dict[str, dict] = {}
    for item in second_doc.get("items") or []:
        if isinstance(item, dict) and "id" in item:
            second_items[item["id"]] = item

    # Build hard-constraint canon id set
    hard_ids = build_hard_constraint_set(canon_dir)
    if not hard_ids:
        print(
            "WARNING: No hard-constraint canon entries found in: " + str(canon_dir),
            file=sys.stderr,
        )

    # Check each first-pass item
    violations: list[str] = []
    for item in first_doc.get("items") or []:
        if not isinstance(item, dict):
            continue
        item_id = item.get("id", "<unknown>")
        rationale = item.get("rationale") or {}
        rule_ids = rationale.get("rule_ids") or []

        citing = rule_ids_cite_hard_constraint(rule_ids, hard_ids)
        if not citing:
            # Not a hard-constraint item — skip
            continue

        # This item must be unchanged in the second pass
        second_item = second_items.get(item_id)
        if second_item is None:
            violations.append(
                f"  item '{item_id}': missing from second-pass artifact"
                f" (hard_constraint rule_ids: {citing})"
            )
            continue

        first_values = item.get("values", {})
        second_values = second_item.get("values", {})

        if not values_equal(first_values, second_values):
            # Determine which fields changed
            changed_fields: list[str] = []
            for field in ("label", "hint", "errors"):
                if first_values.get(field) != second_values.get(field):
                    changed_fields.append(field)
            # Also catch any extra fields that changed
            all_keys = set(first_values.keys()) | set(second_values.keys())
            for k in all_keys - {"label", "hint", "errors"}:
                if first_values.get(k) != second_values.get(k):
                    changed_fields.append(k)

            violations.append(
                f"  item '{item_id}': values.{{{', '.join(changed_fields)}}} mutated"
                f" (hard_constraint rule_ids: {citing})"
            )

    if violations:
        print(
            "HARD-CONSTRAINT IMMUTABILITY VIOLATION: coordination-pass mutated "
            "one or more items governed by hard_constraint:true canon rules.",
            file=sys.stderr,
        )
        for v in violations:
            print(v, file=sys.stderr)
        sys.exit(1)

    # All hard-constraint items are unchanged
    print("OK: all hard-constraint items are unchanged in the second pass.")
    sys.exit(0)


main()
PYEOF
