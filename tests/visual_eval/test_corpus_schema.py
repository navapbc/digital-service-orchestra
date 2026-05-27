from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "plugins" / "dso" / "scripts"))

from label_visual_corpus import validate_fixture  # noqa: E402


@pytest.fixture
def valid_fixture(tmp_path: Path) -> Path:
    """A well-formed fixture directory."""
    fixture = tmp_path / "fixture-001"
    fixture.mkdir()
    (fixture / "screenshot.png").write_bytes(b"\x89PNG\r\n\x1a\n")  # minimal PNG header
    manifest = {
        "fixture_id": "fixture-001",
        "attribution_class": "implementation_drift",
    }
    (fixture / "design_manifest.json").write_text(json.dumps(manifest))
    (fixture / "labels").mkdir()
    return fixture


def test_valid_fixture_passes(valid_fixture: Path) -> None:
    """Well-formed fixture returns (True, [])."""
    result = validate_fixture(valid_fixture)
    assert result.ok is True
    assert result.errors == []


def test_rejects_missing_screenshot(valid_fixture: Path) -> None:
    """Fixture missing screenshot.png fails validation."""
    (valid_fixture / "screenshot.png").unlink()
    result = validate_fixture(valid_fixture)
    assert result.ok is False
    assert any("screenshot.png" in e for e in result.errors)


def test_rejects_missing_manifest(valid_fixture: Path) -> None:
    """Fixture missing design_manifest.json fails validation."""
    (valid_fixture / "design_manifest.json").unlink()
    result = validate_fixture(valid_fixture)
    assert result.ok is False
    assert any("design_manifest.json" in e for e in result.errors)


def test_rejects_missing_labels_dir(valid_fixture: Path) -> None:
    """Fixture missing labels/ subdirectory fails validation."""
    import shutil

    shutil.rmtree(valid_fixture / "labels")
    result = validate_fixture(valid_fixture)
    assert result.ok is False
    assert any("labels" in e for e in result.errors)


def test_rejects_manifest_missing_attribution_class(valid_fixture: Path) -> None:
    """Fixture with manifest missing attribution_class fails validation."""
    (valid_fixture / "design_manifest.json").write_text(json.dumps({"fixture_id": "x"}))
    result = validate_fixture(valid_fixture)
    assert result.ok is False
    assert any("attribution_class" in e for e in result.errors)


def test_rejects_invalid_json_manifest(valid_fixture: Path) -> None:
    """Fixture with invalid JSON manifest fails validation."""
    (valid_fixture / "design_manifest.json").write_text("{not valid json}")
    result = validate_fixture(valid_fixture)
    assert result.ok is False
    assert any("not valid JSON" in e for e in result.errors)


def test_rejects_nonexistent_path() -> None:
    """Non-existent path fails validation."""
    result = validate_fixture("/tmp/nonexistent-fixture-path-xyz")
    assert result.ok is False


def test_every_fixture_has_two_llm_agent_runs() -> None:
    """Post-label_all, every fixture in real corpus has run_1 and run_2 with provenance=llm_agent."""
    corpus_root = REPO_ROOT / "plugins" / "dso" / "data" / "visual-eval-corpus"
    if not corpus_root.exists():
        pytest.skip("Corpus not yet generated")
    fixtures = [
        p for p in corpus_root.iterdir() if p.is_dir() and not p.name.startswith(".")
    ]
    for fixture in fixtures:
        run1_path = fixture / "labels" / "llm_agent_run_1.json"
        run2_path = fixture / "labels" / "llm_agent_run_2.json"
        assert run1_path.exists(), f"Missing llm_agent_run_1.json in {fixture.name}"
        assert run2_path.exists(), f"Missing llm_agent_run_2.json in {fixture.name}"
        run1 = json.loads(run1_path.read_text())
        run2 = json.loads(run2_path.read_text())
        assert run1["provenance"] == "llm_agent"
        assert run2["provenance"] == "llm_agent"
        assert run1["labeler_id"] == "llm_agent_run_1"
        assert run2["labeler_id"] == "llm_agent_run_2"


def test_label_all_idempotent(tmp_path: Path) -> None:
    """label_all is idempotent — second run produces same file count."""
    from label_visual_corpus import label_all

    # Create 4 fixtures, one per class
    for i, cls in enumerate(
        ["implementation_drift", "design_flaw", "mixed", "uncertain"]
    ):
        fixture = tmp_path / f"f{i:03d}"
        fixture.mkdir()
        (fixture / "screenshot.png").write_bytes(b"\x89PNG")
        (fixture / "design_manifest.json").write_text(
            json.dumps({"attribution_class": cls})
        )
        (fixture / "labels").mkdir()

    result1 = label_all(tmp_path)
    files1 = list(tmp_path.glob("*/labels/*.json"))
    result2 = label_all(tmp_path)
    files2 = list(tmp_path.glob("*/labels/*.json"))
    assert len(files1) == len(files2), "Idempotency violation: file count changed"
    assert result1["fixture_count"] == result2["fixture_count"]
