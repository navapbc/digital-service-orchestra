"""Unit tests for figma_merge.identity.identity_match().

Tests cover:
  - ID-1: Primary match — Figma node name matches original component id
  - ID-2: Primary match — Figma node name matches original component name field
  - ID-3: Fallback match — structural position used when name match fails
  - ID-4: Unmatched new — Figma node beyond original list marked unmatched_new
  - ID-5: Unmatched original — Original component with no Figma counterpart marked unmatched_original
  - ID-6: Empty inputs — no crashes on empty lists
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Add the scripts directory so `figma_merge` package is importable.
_SCRIPTS_DIR = str(Path(__file__).resolve().parents[2] / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

try:
    from figma_merge.identity import identity_match  # type: ignore[import]

    _IMPORT_ERROR: Exception | None = None
except (ImportError, ModuleNotFoundError) as exc:
    identity_match = None  # type: ignore[assignment]
    _IMPORT_ERROR = exc


def _require_module() -> None:
    if _IMPORT_ERROR is not None:
        pytest.fail(f"figma_merge.identity could not be imported: {_IMPORT_ERROR}")


# ---------------------------------------------------------------------------
# ID-1: Primary match — Figma node name matches original component id
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestPrimaryMatchById:
    """ID-1: identity_match resolves by name == original component id."""

    def test_name_matches_original_id(self) -> None:
        _require_module()

        figma_nodes = [{"id": "fn-001", "name": "btn-primary"}]
        original = {
            "components": [
                {"id": "btn-primary", "name": "PrimaryButton"},
            ]
        }
        matched_map, unmatched_new, unmatched_original = identity_match(
            figma_nodes, original
        )

        assert "fn-001" in matched_map, "Figma node fn-001 must be in matched_map"
        assert matched_map["fn-001"] == "btn-primary", (
            "fn-001 must map to original id 'btn-primary'"
        )
        assert unmatched_new == [], "No unmatched-new nodes expected"
        assert unmatched_original == [], "No unmatched-original components expected"


# ---------------------------------------------------------------------------
# ID-2: Primary match — Figma node name matches original component name field
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestPrimaryMatchByName:
    """ID-2: identity_match resolves by name == original component name field."""

    def test_name_matches_original_name_field(self) -> None:
        _require_module()

        figma_nodes = [{"id": "fn-002", "name": "PrimaryButton"}]
        original = {
            "components": [
                {"id": "comp-abc", "name": "PrimaryButton"},
            ]
        }
        matched_map, unmatched_new, unmatched_original = identity_match(
            figma_nodes, original
        )

        assert matched_map.get("fn-002") == "comp-abc", (
            "fn-002 must map to comp-abc via name field match"
        )
        assert unmatched_new == []
        assert unmatched_original == []


# ---------------------------------------------------------------------------
# ID-3: Fallback — structural position
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestFallbackPositionalMatch:
    """ID-3: When name match fails, structural position is used as fallback."""

    def test_positional_fallback_used_on_name_mismatch(self) -> None:
        _require_module()

        figma_nodes = [{"id": "fn-003", "name": "CompletelyDifferentName"}]
        original = {
            "components": [
                {"id": "comp-xyz", "name": "SomethingElse"},
            ]
        }
        matched_map, unmatched_new, unmatched_original = identity_match(
            figma_nodes, original
        )

        # Fallback: index 0 in figma_nodes → index 0 in original_components
        assert matched_map.get("fn-003") == "comp-xyz", (
            "Positional fallback must map fn-003 (idx 0) to comp-xyz (idx 0)"
        )
        assert unmatched_new == []
        assert unmatched_original == []


# ---------------------------------------------------------------------------
# ID-4: Unmatched new — Figma node beyond original list
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestUnmatchedNew:
    """ID-4: Figma nodes with no match are marked unmatched_new=True."""

    def test_extra_figma_node_marked_unmatched_new(self) -> None:
        _require_module()

        figma_nodes = [
            {"id": "fn-010", "name": "alpha"},
            {"id": "fn-011", "name": "beta"},  # no corresponding original
        ]
        original = {
            "components": [
                {"id": "comp-1", "name": "alpha"},
            ]
        }
        matched_map, unmatched_new, unmatched_original = identity_match(
            figma_nodes, original
        )

        assert "fn-010" in matched_map, "fn-010 must be matched"
        unmatched_ids = [n.get("id") for n in unmatched_new]
        assert "fn-011" in unmatched_ids, (
            "fn-011 must be in unmatched_new (no original slot)"
        )
        assert all(n.get("unmatched_new") is True for n in unmatched_new), (
            "unmatched_new flag must be True on unmatched nodes"
        )


# ---------------------------------------------------------------------------
# ID-5: Unmatched original — Original component with no Figma counterpart
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestUnmatchedOriginal:
    """ID-5: Original components not matched by any Figma node are marked unmatched_original=True."""

    def test_extra_original_component_marked_unmatched_original(self) -> None:
        _require_module()

        figma_nodes = [{"id": "fn-020", "name": "alpha"}]
        original = {
            "components": [
                {"id": "comp-1", "name": "alpha"},
                {"id": "comp-2", "name": "beta"},  # no Figma node
            ]
        }
        matched_map, unmatched_new, unmatched_original = identity_match(
            figma_nodes, original
        )

        assert unmatched_new == []
        unmatched_orig_ids = [c.get("id") for c in unmatched_original]
        assert "comp-2" in unmatched_orig_ids, (
            "comp-2 must be in unmatched_original (no Figma counterpart)"
        )
        assert all(c.get("unmatched_original") is True for c in unmatched_original), (
            "unmatched_original flag must be True on unmatched originals"
        )


# ---------------------------------------------------------------------------
# ID-6: Empty inputs — no crashes
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestEmptyInputs:
    """ID-6: identity_match handles empty inputs without raising."""

    def test_empty_figma_nodes_and_empty_original(self) -> None:
        _require_module()

        matched_map, unmatched_new, unmatched_original = identity_match(
            [], {"components": []}
        )

        assert matched_map == {}
        assert unmatched_new == []
        assert unmatched_original == []

    def test_empty_figma_nodes_with_original_components(self) -> None:
        _require_module()

        original = {"components": [{"id": "comp-1", "name": "alpha"}]}
        matched_map, unmatched_new, unmatched_original = identity_match([], original)

        assert matched_map == {}
        assert unmatched_new == []
        assert len(unmatched_original) == 1, (
            "One unmatched original expected when no Figma nodes provided"
        )
