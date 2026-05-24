#!/usr/bin/env bash
# check-corpus-schema.sh — validate UI reference corpus YAML files against schema rules.
#
# Usage:
#   check-corpus-schema.sh <corpus-directory>
#
# Exit codes:
#   0 — all YAML files in the directory pass schema validation
#   1 — one or more files fail validation (errors printed to stderr)
#
# Validation rules applied to each .yaml file (excluding _index.yaml, _schema.yaml):
#   1. File is non-empty and contains valid YAML
#   2. Required fields present: id, title, domain, source, license
#   3. compliance field is a list (may be empty) — accepts any string values
#   4. license value is a non-empty string
#   5. severity value is one of: informational, minor, important, critical
#   6. domain, component, action, story_type are lists (if present)
#
# This script uses Python (available in the project's venv) for YAML parsing.

set -euo pipefail

CORPUS_DIR="${1:-}"

if [[ -z "$CORPUS_DIR" ]]; then
    printf 'check-corpus-schema.sh: usage: %s <corpus-directory>\n' "$0" >&2
    exit 1
fi

if [[ ! -d "$CORPUS_DIR" ]]; then
    printf 'check-corpus-schema.sh: directory not found: %s\n' "$CORPUS_DIR" >&2
    exit 1
fi

# Use Python for YAML parsing — avoids dependency on yq or other tools.
python3 - "$CORPUS_DIR" <<'PYTHON_EOF'
import sys
import os
from pathlib import Path

import yaml  # PyYAML is available in this project

corpus_dir = Path(sys.argv[1])

# Fields that must be present in every entry
REQUIRED_FIELDS = {"id", "title", "domain", "source", "license"}

# Fields that, if present, must be lists
LIST_FIELDS = {"domain", "component", "action", "story_type", "compliance"}

# Valid severity values (informational is the standard for ui-reference corpus)
VALID_SEVERITY = {"informational", "minor", "important", "critical"}

# Files to skip
SKIP_NAMES = {"_index.yaml", "_schema.yaml"}

errors: list[str] = []
file_count = 0

yaml_files = sorted(
    f for f in corpus_dir.glob("*.yaml") if f.name not in SKIP_NAMES
)

if not yaml_files:
    print(f"check-corpus-schema.sh: WARNING: no YAML files found in {corpus_dir}", file=sys.stderr)
    # Empty directory is not an error for the schema checker itself
    sys.exit(0)

for yaml_path in yaml_files:
    file_count += 1
    fname = yaml_path.name

    # Rule 1: Non-empty and valid YAML
    content = yaml_path.read_text(encoding="utf-8")
    if not content.strip():
        errors.append(f"{fname}: file is empty")
        continue

    try:
        docs = list(yaml.safe_load_all(content))
    except yaml.YAMLError as exc:
        errors.append(f"{fname}: YAML parse error — {exc}")
        continue

    # Normalize to list of entries
    entries: list[dict] = []
    for doc in docs:
        if doc is None:
            continue
        if isinstance(doc, list):
            entries.extend(doc)
        elif isinstance(doc, dict):
            entries.append(doc)

    if not entries:
        errors.append(f"{fname}: no valid YAML documents found")
        continue

    for i, entry in enumerate(entries):
        entry_label = f"{fname}[{i}]" if len(entries) > 1 else fname
        entry_id = entry.get("id", f"<entry {i}>")

        # Rule 2: Required fields
        for field in REQUIRED_FIELDS:
            if field not in entry:
                errors.append(f"{entry_label} ({entry_id}): missing required field '{field}'")

        # Rule 3/6: List fields must be lists (if present)
        for field in LIST_FIELDS:
            if field in entry and entry[field] is not None:
                val = entry[field]
                if not isinstance(val, (list, tuple)):
                    errors.append(
                        f"{entry_label} ({entry_id}): field '{field}' must be a list, "
                        f"got {type(val).__name__}: {val!r}"
                    )

        # Rule 4: license must be a non-empty string
        if "license" in entry:
            lic = entry["license"]
            if not isinstance(lic, str) or not lic.strip():
                errors.append(
                    f"{entry_label} ({entry_id}): 'license' must be a non-empty string, got {lic!r}"
                )

        # Rule 5: severity must be in valid set (if present)
        if "severity" in entry:
            sev = entry["severity"]
            if sev not in VALID_SEVERITY:
                errors.append(
                    f"{entry_label} ({entry_id}): 'severity' value {sev!r} not in "
                    f"{sorted(VALID_SEVERITY)}"
                )

if errors:
    print(f"check-corpus-schema.sh: {len(errors)} schema violation(s) found:", file=sys.stderr)
    for err in errors:
        print(f"  ERROR: {err}", file=sys.stderr)
    sys.exit(1)

print(f"check-corpus-schema.sh: OK — {file_count} file(s) passed schema validation")
sys.exit(0)
PYTHON_EOF
