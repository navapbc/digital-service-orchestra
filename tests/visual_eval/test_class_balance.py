from __future__ import annotations

import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "plugins" / "dso" / "scripts"))

from label_visual_corpus import validate_fixture  # noqa: E402

CORPUS_ROOT = REPO_ROOT / "plugins" / "dso" / "data" / "visual-eval-corpus"


def _get_all_fixtures() -> list[Path]:
    if not CORPUS_ROOT.exists():
        return []
    return [
        p for p in CORPUS_ROOT.iterdir() if p.is_dir() and not p.name.startswith(".")
    ]


def test_corpus_size_and_balance() -> None:
    """Corpus has >=40 total fixtures with >=10 per attribution_class."""
    fixtures = _get_all_fixtures()
    assert len(fixtures) >= 40, f"Expected >=40 fixtures, found {len(fixtures)}"

    by_class: dict[str, int] = {}
    for fixture in fixtures:
        manifest_path = fixture / "design_manifest.json"
        if not manifest_path.exists():
            continue
        try:
            manifest = json.loads(manifest_path.read_text())
            cls = manifest.get("attribution_class", "unknown")
            by_class[cls] = by_class.get(cls, 0) + 1
        except (json.JSONDecodeError, OSError):
            pass

    for cls, count in by_class.items():
        assert count >= 10, f"Class '{cls}' has only {count} fixtures (need >=10)"

    required_classes = {"implementation_drift", "design_flaw", "mixed", "uncertain"}
    for cls in required_classes:
        assert cls in by_class, f"Missing required class: {cls}"


def test_every_fixture_schema_valid() -> None:
    """Every fixture passes schema validation."""
    fixtures = _get_all_fixtures()
    assert len(fixtures) > 0, "No fixtures found in corpus"

    failures = []
    for fixture in fixtures:
        result = validate_fixture(fixture)
        if not result.ok:
            failures.append(f"{fixture.name}: {result.errors}")

    assert len(failures) == 0, "Schema validation failures:\n" + "\n".join(failures)
