"""
Visual-eval corpus labeling utilities.

Fixture structure:
  {CORPUS_ROOT}/<fixture-id>/
    screenshot.png
    design_manifest.json   # must contain 'attribution_class'
    labels/                # populated by label_all()
      llm_agent_run_1.json
      llm_agent_run_2.json
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import NamedTuple


REQUIRED_FILES = ("screenshot.png", "design_manifest.json")
REQUIRED_MANIFEST_FIELDS = ("attribution_class",)
VALID_PROVENANCES = ("heuristic", "llm_agent")


class ValidationResult(NamedTuple):
    ok: bool
    errors: list[str]


def validate_fixture(fixture_path: str | Path) -> ValidationResult:
    """Validate a single fixture directory structure and content.

    Returns (True, []) on success, (False, [errors]) on failure.
    """
    path = Path(fixture_path)
    errors: list[str] = []

    if not path.is_dir():
        return ValidationResult(ok=False, errors=[f"Not a directory: {path}"])

    # Check required files
    for required in REQUIRED_FILES:
        if not (path / required).exists():
            errors.append(f"Missing required file: {required}")

    # Check labels/ subdirectory
    labels_dir = path / "labels"
    if not labels_dir.is_dir():
        errors.append("Missing required subdirectory: labels/")

    # Validate design_manifest.json content
    manifest_path = path / "design_manifest.json"
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text())
            for field in REQUIRED_MANIFEST_FIELDS:
                if field not in manifest:
                    errors.append(
                        f"design_manifest.json missing required field: {field}"
                    )
        except json.JSONDecodeError as exc:
            errors.append(f"design_manifest.json is not valid JSON: {exc}")

    return ValidationResult(ok=len(errors) == 0, errors=errors)
