#!/usr/bin/env bash
# check-gov-copy-artifact.sh — Validate a gov-copy artifact YAML file.
#
# Usage:
#   bash check-gov-copy-artifact.sh <artifact.yaml>
#
# Exit codes:
#   0   Artifact conforms to the gov-copy-artifact schema
#   1   Artifact is invalid (errors printed to stderr)
#   2   Usage error or missing dependency
#
# Schema reference: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/gov-copy-artifact.md
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "ERROR: Usage: $(basename "$0") <artifact.yaml>" >&2
  exit 2
fi

ARTIFACT_FILE="$1"

if [[ ! -f "$ARTIFACT_FILE" ]]; then
  echo "ERROR: File not found: $ARTIFACT_FILE" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not found in PATH" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Inline Python validator (uses PyYAML, which is available in the project env)
# ---------------------------------------------------------------------------
python3 - "$ARTIFACT_FILE" <<'PYEOF'
from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(2)


def validate(path: Path) -> list[str]:
    """Return list of error strings; empty list = valid."""
    errors: list[str] = []

    try:
        with path.open() as fh:
            doc = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        return [f"YAML parse error: {exc}"]

    if doc is None:
        return ["Artifact is empty."]

    if not isinstance(doc, dict):
        return [f"Top-level must be a mapping, got {type(doc).__name__}."]

    # --- schema_version ---
    if "schema_version" not in doc:
        errors.append("Missing top-level field: 'schema_version'.")
    elif not isinstance(doc["schema_version"], int):
        errors.append(
            f"'schema_version' must be an integer, got {type(doc['schema_version']).__name__}."
        )

    # --- items ---
    if "items" not in doc:
        errors.append("Missing top-level field: 'items'.")
    elif not isinstance(doc["items"], list):
        errors.append(
            f"'items' must be a list, got {type(doc['items']).__name__}."
        )
    else:
        for i, item in enumerate(doc["items"]):
            item_errors = _validate_item(i, item)
            errors.extend(item_errors)

    return errors


def _validate_item(idx: int, item: object) -> list[str]:
    """Validate a single items[] entry."""
    prefix = f"items[{idx}]"
    errors: list[str] = []

    if not isinstance(item, dict):
        return [f"{prefix}: must be a mapping, got {type(item).__name__}."]

    # --- id ---
    if "id" not in item:
        errors.append(f"{prefix}: missing required field 'id'.")
    elif not isinstance(item["id"], str):
        errors.append(f"{prefix}.id: must be a string, got {type(item['id']).__name__}.")

    # --- values ---
    if "values" not in item:
        errors.append(f"{prefix}: missing required field 'values'.")
    else:
        errors.extend(_validate_values(prefix, item["values"]))

    # --- rationale ---
    if "rationale" not in item:
        errors.append(f"{prefix}: missing required field 'rationale'.")
    else:
        errors.extend(_validate_rationale(prefix, item["rationale"]))

    # --- checks ---
    if "checks" not in item:
        errors.append(f"{prefix}: missing required field 'checks'.")
    else:
        errors.extend(_validate_checks(prefix, item["checks"]))

    return errors


def _validate_values(prefix: str, values: object) -> list[str]:
    """Validate the values{} block."""
    errors: list[str] = []
    p = f"{prefix}.values"

    if not isinstance(values, dict):
        return [f"{p}: must be a mapping, got {type(values).__name__}."]

    for field in ("label", "hint"):
        if field not in values:
            errors.append(f"{p}: missing required field '{field}'.")
        elif not isinstance(values[field], str):
            errors.append(
                f"{p}.{field}: must be a string, got {type(values[field]).__name__}."
            )

    if "errors" not in values:
        errors.append(f"{p}: missing required field 'errors'.")
    elif not isinstance(values["errors"], dict):
        errors.append(
            f"{p}.errors: must be a mapping, got {type(values['errors']).__name__}."
        )

    return errors


def _validate_rationale(prefix: str, rationale: object) -> list[str]:
    """Validate the rationale{} block."""
    errors: list[str] = []
    p = f"{prefix}.rationale"

    if not isinstance(rationale, dict):
        return [f"{p}: must be a mapping, got {type(rationale).__name__}."]

    if "rule_ids" not in rationale:
        errors.append(f"{p}: missing required field 'rule_ids'.")
    elif not isinstance(rationale["rule_ids"], list):
        errors.append(
            f"{p}.rule_ids: must be a list, got {type(rationale['rule_ids']).__name__}."
        )

    if "conflicts" not in rationale:
        errors.append(f"{p}: missing required field 'conflicts'.")
    elif not isinstance(rationale["conflicts"], list):
        errors.append(
            f"{p}.conflicts: must be a list, got {type(rationale['conflicts']).__name__}."
        )

    if "deviations" not in rationale:
        errors.append(f"{p}: missing required field 'deviations'.")
    elif not isinstance(rationale["deviations"], list):
        errors.append(
            f"{p}.deviations: must be a list, got {type(rationale['deviations']).__name__}."
        )
    else:
        for j, dev in enumerate(rationale["deviations"]):
            dp = f"{p}.deviations[{j}]"
            if not isinstance(dev, dict):
                errors.append(f"{dp}: must be a mapping, got {type(dev).__name__}.")
                continue
            for field in ("rule_id", "reason"):
                if field not in dev:
                    errors.append(f"{dp}: missing required field '{field}'.")
                elif not isinstance(dev[field], str):
                    errors.append(
                        f"{dp}.{field}: must be a string, got {type(dev[field]).__name__}."
                    )

    return errors


def _validate_checks(prefix: str, checks: object) -> list[str]:
    """Validate the checks{} block."""
    errors: list[str] = []
    p = f"{prefix}.checks"

    if not isinstance(checks, dict):
        return [f"{p}: must be a mapping, got {type(checks).__name__}."]

    # fk_grade: integer
    if "fk_grade" not in checks:
        errors.append(f"{p}: missing required field 'fk_grade'.")
    elif not isinstance(checks["fk_grade"], int):
        errors.append(
            f"{p}.fk_grade: must be an integer, got {type(checks['fk_grade']).__name__}."
        )

    # banned_words_found: list
    if "banned_words_found" not in checks:
        errors.append(f"{p}: missing required field 'banned_words_found'.")
    elif not isinstance(checks["banned_words_found"], list):
        errors.append(
            f"{p}.banned_words_found: must be a list, got {type(checks['banned_words_found']).__name__}."
        )

    # active_voice: bool
    if "active_voice" not in checks:
        errors.append(f"{p}: missing required field 'active_voice'.")
    elif not isinstance(checks["active_voice"], bool):
        errors.append(
            f"{p}.active_voice: must be a boolean, got {type(checks['active_voice']).__name__}."
        )

    # source: string
    if "source" not in checks:
        errors.append(f"{p}: missing required field 'source'.")
    elif not isinstance(checks["source"], str):
        errors.append(
            f"{p}.source: must be a string, got {type(checks['source']).__name__}."
        )

    return errors


def main() -> int:
    artifact_path = Path(sys.argv[1])
    errors = validate(artifact_path)
    if errors:
        print(f"INVALID: {artifact_path}", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    print(f"OK: {artifact_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
