"""Unit tests for the copy_artifact_path helper script.

Covers story bf1e-3845-47fc-4dc0 (copy.artifact_dir config + path validation),
task f963-ff84-c3e7-4cf5 (TRIVIAL sole task).

DDs tested:
  - Good relative path copy/<epic-id>.yaml is accepted
  - Absolute path /etc/passwd is rejected
  - Path traversal copy/../../../etc/passwd is rejected
  - Path with epic-id interpolation resolves safely

RED markers (before copy_artifact_path.py exists):
  test_good_relative_path_accepted
  test_absolute_path_rejected
  test_traversal_path_rejected
  test_epic_id_interpolation_accepted
  test_escape_after_resolution_rejected
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens-adjacent naming; load via importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[4]
SCRIPT_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "copy_artifact_path.py"
)


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("copy_artifact_path", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def cap() -> ModuleType:
    """Return the copy_artifact_path module, skipping all tests if absent."""
    if not SCRIPT_PATH.exists():
        pytest.skip(f"Script not found: {SCRIPT_PATH}")
    return _load_module()


# ---------------------------------------------------------------------------
# Tests for validate_artifact_path
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestValidateArtifactPath:
    """validate_artifact_path enforces safe path rules for copy artifact output."""

    # [test_good_relative_path_accepted]
    def test_good_relative_path_accepted(
        self, tmp_path: Path, cap: ModuleType
    ) -> None:
        """A clean relative path under the project root must be accepted (exit 0 / no exception)."""
        result = cap.validate_artifact_path("copy/abc123.yaml", project_root=tmp_path)
        # validate_artifact_path returns the resolved Path on success
        assert result is not None
        assert str(result).startswith(str(tmp_path))

    # [test_absolute_path_rejected]
    def test_absolute_path_rejected(self, tmp_path: Path, cap: ModuleType) -> None:
        """An absolute path must be rejected with ValueError."""
        with pytest.raises(ValueError, match="absolute"):
            cap.validate_artifact_path("/etc/passwd", project_root=tmp_path)

    # [test_traversal_path_rejected]
    def test_traversal_path_rejected(self, tmp_path: Path, cap: ModuleType) -> None:
        """A path containing '..' segments must be rejected with ValueError."""
        with pytest.raises(ValueError, match=r"\.\.|traversal|escape"):
            cap.validate_artifact_path(
                "copy/../../../etc/passwd", project_root=tmp_path
            )

    # [test_epic_id_interpolation_accepted]
    def test_epic_id_interpolation_accepted(
        self, tmp_path: Path, cap: ModuleType
    ) -> None:
        """copy/<epic-id>.yaml with a realistic epic-id must be accepted."""
        epic_id = "f360-3a5b-b8f3-4f86"
        result = cap.validate_artifact_path(
            f"copy/{epic_id}.yaml", project_root=tmp_path
        )
        assert result is not None
        assert epic_id in str(result)

    # [test_escape_after_resolution_rejected]
    def test_escape_after_resolution_rejected(
        self, tmp_path: Path, cap: ModuleType
    ) -> None:
        """A path that resolves outside the project root must be rejected."""
        # Even without explicit '..', a symlink could cause escape;
        # but we also test that the resolution guard fires for traversal via symlink.
        # Here we test the plain traversal case since symlinks require setup:
        with pytest.raises(ValueError):
            cap.validate_artifact_path(
                "copy/../../outside.yaml", project_root=tmp_path
            )

    def test_nested_relative_path_accepted(
        self, tmp_path: Path, cap: ModuleType
    ) -> None:
        """A nested relative path that stays within the project root is accepted."""
        result = cap.validate_artifact_path(
            "copy/2026/epic-id.yaml", project_root=tmp_path
        )
        assert result is not None

    def test_dot_dot_in_filename_rejected(
        self, tmp_path: Path, cap: ModuleType
    ) -> None:
        """Path segments containing '..' must be rejected even mid-path."""
        with pytest.raises(ValueError):
            cap.validate_artifact_path(
                "copy/valid/../escape/artifact.yaml", project_root=tmp_path
            )


# ---------------------------------------------------------------------------
# Tests for resolve_artifact_path (convenience wrapper)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestResolveArtifactPath:
    """resolve_artifact_path combines artifact_dir + epic_id with validation."""

    def test_combines_dir_and_epic_id(self, tmp_path: Path, cap: ModuleType) -> None:
        """resolve_artifact_path(artifact_dir, epic_id) yields <dir>/<epic_id>.yaml."""
        result = cap.resolve_artifact_path(
            artifact_dir="copy/", epic_id="abc-123", project_root=tmp_path
        )
        assert str(result).endswith("abc-123.yaml")

    def test_rejects_absolute_artifact_dir(
        self, tmp_path: Path, cap: ModuleType
    ) -> None:
        """An absolute artifact_dir must be rejected."""
        with pytest.raises(ValueError, match="absolute"):
            cap.resolve_artifact_path(
                artifact_dir="/etc/copy", epic_id="abc-123", project_root=tmp_path
            )

    def test_rejects_traversal_in_dir(self, tmp_path: Path, cap: ModuleType) -> None:
        """A traversal in artifact_dir must be rejected."""
        with pytest.raises(ValueError):
            cap.resolve_artifact_path(
                artifact_dir="../../etc",
                epic_id="abc-123",
                project_root=tmp_path,
            )

    def test_default_dir_copy_slash(self, tmp_path: Path, cap: ModuleType) -> None:
        """Default artifact_dir of 'copy/' results in copy/<epic_id>.yaml."""
        result = cap.resolve_artifact_path(
            artifact_dir="copy/", epic_id="f360-3a5b", project_root=tmp_path
        )
        # Should be <project_root>/copy/f360-3a5b.yaml
        expected = tmp_path / "copy" / "f360-3a5b.yaml"
        assert result == expected
