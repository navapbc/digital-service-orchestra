#!/usr/bin/env python3
"""check-corpus-schema.py — Validate UI/UX reference corpus YAML files.

Usage:
    python3 check-corpus-schema.py <corpus_dir> [--schema <schema_path>]
        [--validate-index]

The validator:
  - Reads _schema.yaml from the corpus directory (or --schema path)
  - Validates all .yaml files (except _schema.yaml, _schema-anti-patterns.yaml,
    and _index.yaml) recursively against:
      * required_fields: all listed fields must be present
      * tag_vocabulary: field values must be in the declared vocabulary
      * strict mode: no unknown fields beyond required_fields + tag_vocabulary keys
  - Exits 0 if all files are valid
  - Exits 1 if any file is invalid, printing clear error messages
  - With --validate-index: also verifies every path: entry in _index.yaml resolves
    to an existing file (skipped silently if _index.yaml is absent)
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

    # --- Parse YAML (handle multi-document files by reading first document) ---
    try:
        with entry_path.open() as fh:
            raw = fh.read()
        # Use safe_load_all to support multi-document YAML (frontmatter + body separated by ---)
        content = None
        for doc in yaml.safe_load_all(raw):
            if doc is not None:
                content = doc
                break
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


_SKIP_NAMES = {"_schema.yaml", "_schema-anti-patterns.yaml", "_index.yaml"}


def validate_index(corpus_dir: Path, index_path: Path) -> list[str]:
    """Validate that every path: entry in _index.yaml resolves to an existing file.

    Returns a list of error strings (empty = valid).
    If index_path does not exist, returns [] (skip silently).
    """
    errors: list[str] = []
    if not index_path.exists():
        return errors

    try:
        with index_path.open() as fh:
            index = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        errors.append(f"_index.yaml YAML syntax error: {exc}")
        return errors

    if not isinstance(index, dict):
        errors.append("_index.yaml: expected a YAML mapping at top level.")
        return errors

    entries = index.get("entries", [])
    if not isinstance(entries, list):
        errors.append("_index.yaml: 'entries' key must be a list.")
        return errors

    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(
                f"_index.yaml entry [{i}]: expected a mapping, got {type(entry).__name__}."
            )
            continue
        # Support both 'path' (old format) and 'file_path' (new structured format)
        rel_path = entry.get("path") or entry.get("file_path")
        if not rel_path:
            errors.append(
                f"_index.yaml entry [{i}]: missing 'path' or 'file_path' field."
            )
            continue
        resolved = corpus_dir / rel_path
        if not resolved.exists():
            errors.append(
                f"_index.yaml entry '{rel_path}': file not found at {resolved}."
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
    parser.add_argument(
        "--validate-index",
        action="store_true",
        default=False,
        help="Also verify every path: entry in _index.yaml resolves to an existing file.",
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

    # Collect all .yaml files recursively, skipping schema and index files
    entry_files = sorted(
        f for f in corpus_dir.rglob("*.yaml") if f.name not in _SKIP_NAMES
    )

    total_errors = 0

    if entry_files:
        for entry_path in entry_files:
            errors = validate_file(entry_path, schema)
            if errors:
                total_errors += len(errors)
                print(f"FAIL: {entry_path.relative_to(corpus_dir)}")
                for err in errors:
                    print(f"  - {err}")
            else:
                print(f"OK:   {entry_path.relative_to(corpus_dir)}")

        if total_errors > 0:
            print(f"\n{total_errors} error(s) found across {len(entry_files)} file(s).")
        else:
            print(f"All {len(entry_files)} file(s) are valid.")

    # --validate-index check
    if args.validate_index:
        index_path = corpus_dir / "_index.yaml"
        index_errors = validate_index(corpus_dir, index_path)
        if index_errors:
            total_errors += len(index_errors)
            print("FAIL: _index.yaml path resolution")
            for err in index_errors:
                print(f"  - {err}")
        elif index_path.exists():
            print("OK:   _index.yaml path resolution")

    return 0 if total_errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
