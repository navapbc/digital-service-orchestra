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
