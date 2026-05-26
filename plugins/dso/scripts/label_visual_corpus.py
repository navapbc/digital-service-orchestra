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

import datetime as _dt
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


_STUB_LABEL_TABLE = {
    "implementation_drift": "implementation_drift",
    "design_flaw": "design_flaw",
    "mixed": "mixed",
    "uncertain": "uncertain",
}


def label_fixture(
    fixture_dir: str | Path,
    run_id: int,
    temperature: float,
    *,
    stub_mode: bool = True,
) -> dict:
    """Label a single fixture using an LLM agent run (or stub for testing).

    Returns the label dict. Writes labels/llm_agent_run_<run_id>.json.
    """
    fixture_path = Path(fixture_dir)
    manifest = json.loads((fixture_path / "design_manifest.json").read_text())

    if stub_mode:
        # Deterministic stub: returns the manifest's attribution_class,
        # optionally perturbed by temperature for variance.
        true_class = manifest.get("attribution_class", "uncertain")
        if temperature > 0.3 and run_id == 2:
            # Slight perturbation: 1 in 10 fixtures gets a different label
            fixture_idx = (
                int(fixture_path.name.rsplit("-", 1)[-1])
                if "-" in fixture_path.name
                else 0
            )
            if fixture_idx % 10 == 0:
                # Perturb to a different class for variance
                other_classes = [c for c in _STUB_LABEL_TABLE if c != true_class]
                true_class = other_classes[0] if other_classes else true_class
        predicted_class = _STUB_LABEL_TABLE.get(true_class, true_class)
        confidence = "high" if temperature == 0 else "medium"
    else:
        # Live API path — not implemented; spike documented as stub-only for now.
        raise NotImplementedError(
            "Live API labeling not yet implemented; use stub_mode=True"
        )

    label = {
        "labeler_id": f"llm_agent_run_{run_id}",
        "provenance": "llm_agent",
        "attribution_class": predicted_class,
        "attribution_confidence": confidence,
        "temperature": temperature,
        "labeled_at": _dt.datetime.now(_dt.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
    }
    label_path = fixture_path / "labels" / f"llm_agent_run_{run_id}.json"
    label_path.write_text(json.dumps(label, indent=2))
    return label


def label_all(corpus_dir: str | Path, *, stub_mode: bool = True, runs: int = 3) -> dict:
    """Label every fixture with N LLM agent runs and write corpus_metadata.json."""
    from compute_kappa import compute_kappa

    root = Path(corpus_dir)
    fixtures = sorted(
        p for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")
    )

    labeled_count = 0
    temperatures = [0.0] + [round(0.3 + 0.2 * i, 1) for i in range(runs - 1)]
    temperatures = temperatures[:runs]

    for fixture in fixtures:
        ok, errors = validate_fixture(fixture)
        if not ok:
            continue
        for run_id in range(1, runs + 1):
            label_fixture(
                fixture,
                run_id=run_id,
                temperature=temperatures[run_id - 1],
                stub_mode=stub_mode,
            )
        labeled_count += 1

    # Compute kappa
    try:
        kappa = compute_kappa(corpus_dir)
    except ValueError:
        kappa = 0.0

    metadata = {
        "cohens_kappa": kappa,
        "fixture_count": labeled_count,
        "labeler_ids": [f"llm_agent_run_{i}" for i in range(1, runs + 1)],
        "runs_per_fixture": runs,
        "temperatures": temperatures,
        "labeled_at": _dt.datetime.now(_dt.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "stub_mode": stub_mode,
    }
    metadata_path = root / "corpus_metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2))
    return metadata
