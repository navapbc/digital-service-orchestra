#!/usr/bin/env python3
"""check-corpus-schema.py — Validate UI/UX reference corpus YAML files.

Usage:
    python3 check-corpus-schema.py <corpus_dir> [--schema <schema_path>]

The validator:
  - Reads _schema.yaml from the corpus directory (or --schema path)
  - Validates all .yaml files (except _schema.yaml) against:
      * required_fields: all listed fields must be present
      * tag_vocabulary: field values must be in the declared vocabulary
      * strict mode: no unknown fields beyond required_fields + tag_vocabulary keys
  - Exits 0 if all files are valid
  - Exits 1 if any file is invalid, printing clear error messages
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(2)


def load_schema(schema_path: Path) -> dict:
    """Load and return the schema definition from _schema.yaml."""
    if not schema_path.exists():
        print(f"ERROR: Schema file not found: {schema_path}", file=sys.stderr)
        sys.exit(2)
    with schema_path.open() as fh:
        schema = yaml.safe_load(fh)
    if not isinstance(schema, dict):
        print(
            f"ERROR: Schema file is not a valid YAML mapping: {schema_path}",
            file=sys.stderr,
        )
        sys.exit(2)
    return schema


def validate_file(entry_path: Path, schema: dict) -> list[str]:
    """Validate a single corpus entry YAML file against the schema.

    Returns a list of error strings (empty = valid).
    """
    errors: list[str] = []

    # --- Parse YAML ---
    try:
        with entry_path.open() as fh:
            content = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        errors.append(f"YAML syntax error: {exc}")
        return errors

    # --- Empty file check ---
    if content is None or content == {}:
        errors.append("File is empty or contains no YAML data.")
        return errors

    if not isinstance(content, dict):
        errors.append(
            f"Expected a YAML mapping at top level, got {type(content).__name__}."
        )
        return errors

    required_fields: list[str] = schema.get("required_fields", [])
    tag_vocabulary: dict[str, list] = schema.get("tag_vocabulary", {})
    optional_fields: list[str] = schema.get("optional_fields", [])

    # Build the set of known field names (required + vocabulary keys + optional)
    known_fields: set[str] = (
        set(required_fields) | set(tag_vocabulary.keys()) | set(optional_fields)
    )

    # --- Required fields check ---
    for field in required_fields:
        if field not in content:
            errors.append(f"Missing required field: '{field}'.")

    # --- Vocabulary check ---
    for field, vocab in tag_vocabulary.items():
        if field in content:
            value = content[field]
            # Handle list values: each element must be in the vocabulary.
            # An empty list is treated as "field not set" and passes silently.
            if isinstance(value, list):
                if value:  # non-empty list
                    invalid = [v for v in value if v not in vocab]
                    if invalid:
                        errors.append(
                            f"Field '{field}' contains value(s) {invalid} which are not "
                            f"in the vocabulary {vocab}."
                        )
            elif value is None or value == "":
                pass  # None/empty string treated as "not set"
            elif value not in vocab:
                errors.append(
                    f"Field '{field}' has value '{value}' which is not in the vocabulary "
                    f"{vocab}."
                )

    # --- Strict mode: no unknown extra fields ---
    for field in content:
        if field not in known_fields:
            errors.append(
                f"Unknown field '{field}' (strict mode: only fields in required_fields "
                f"and tag_vocabulary are allowed)."
            )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate UI/UX reference corpus YAML files against _schema.yaml."
    )
    parser.add_argument(
        "corpus_dir",
        type=Path,
        help="Directory containing corpus .yaml files and _schema.yaml.",
    )
    parser.add_argument(
        "--schema",
        type=Path,
        default=None,
        help="Path to _schema.yaml (default: <corpus_dir>/_schema.yaml).",
    )
    args = parser.parse_args()

    corpus_dir: Path = args.corpus_dir
    if not corpus_dir.is_dir():
        print(
            f"ERROR: corpus_dir does not exist or is not a directory: {corpus_dir}",
            file=sys.stderr,
        )
        return 1

    schema_path: Path = args.schema if args.schema else corpus_dir / "_schema.yaml"
    schema = load_schema(schema_path)

    # Collect all .yaml files, skipping _schema.yaml
    entry_files = sorted(
        f for f in corpus_dir.glob("*.yaml") if f.name != "_schema.yaml"
    )

    if not entry_files:
        # No corpus entries to validate — pass silently
        return 0

    total_errors = 0
    for entry_path in entry_files:
        errors = validate_file(entry_path, schema)
        if errors:
            total_errors += len(errors)
            print(f"FAIL: {entry_path.name}")
            for err in errors:
                print(f"  - {err}")
        else:
            print(f"OK:   {entry_path.name}")

    if total_errors > 0:
        print(f"\n{total_errors} error(s) found across {len(entry_files)} file(s).")
        return 1

    print(f"All {len(entry_files)} file(s) are valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
