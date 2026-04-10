"""Unit tests for figma_merge.spatial_merge.merge_spatial() (RED phase).

Tests cover:
  - SM-1: spatial_hint from Figma overrides original spatial_hint
  - SM-2: behavioral specs in tokens (Interaction Behaviors) are unchanged
  - SM-3: unmatched Figma-only component added with tag=NEW, designer_added=True, behavioral_spec_status=INCOMPLETE
  - SM-4: unmatched original with behavioral_spec_status=INCOMPLETE removed silently
  - SM-5: unmatched original with behavioral_spec_status=COMPLETE removed with a warning string
  - SM-6: fills and strokes reflect Figma values
  - SM-7: text field reflects Figma characters value

All tests are expected to FAIL (ModuleNotFoundError) because
figma_merge.spatial_merge does not exist yet (RED phase of TDD).
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Add the scripts directory so `figma_merge` package is importable.
_SCRIPTS_DIR = str(Path(__file__).resolve().parents[2] / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# This import will raise ModuleNotFoundError because spatial_merge submodule
# does not exist yet — this is the expected RED state.
from figma_merge.spatial_merge import merge_spatial  # noqa: E402


# ---------------------------------------------------------------------------
# SM-1: spatial_hint visual override
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestSpatialHintOverride:
    """SM-1: Figma spatial_hint overrides original spatial_hint."""

    def test_SM_1_figma_spatial_hint_overrides_original(self) -> None:
        """SM-1: Given matched components with different spatial_hints,
        merge_spatial() must use the Figma-derived spatial_hint in the output."""
        original = [
            {
                "id": "btn-primary",
                "spatial_hint": {"x": 0, "y": 0, "width": 100, "height": 40},
                "tokens": {},
            }
        ]
        figma_components = [
            {
                "id": "btn-primary",
                "spatial_hint": {"x": 10, "y": 20, "width": 120, "height": 50},
            }
        ]
        matched = [("btn-primary", "btn-primary")]
        unmatched_new: list = []
        unmatched_original: list = []

        result, warnings = merge_spatial(
            original=original,
            figma_components=figma_components,
            matched=matched,
            unmatched_new=unmatched_new,
            unmatched_original=unmatched_original,
        )

        output = {c["id"]: c for c in result}
        assert output["btn-primary"]["spatial_hint"] == {
            "x": 10,
            "y": 20,
            "width": 120,
            "height": 50,
        }, "spatial_hint must reflect Figma-derived value (visual override)"


# ---------------------------------------------------------------------------
# SM-2: behavioral specs unchanged
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestBehavioralSpecsPreserved:
    """SM-2: Behavioral specs in tokens Interaction Behaviors section are unchanged."""

    def test_SM_2_behavioral_spec_content_unchanged(self) -> None:
        """SM-2: Given a component with behavioral specs in tokens (Interaction
        Behaviors section), merge_spatial() must not alter that content."""
        original = [
            {
                "id": "toggle-switch",
                "spatial_hint": {"x": 0, "y": 0, "width": 60, "height": 30},
                "tokens": {
                    "Interaction Behaviors": {
                        "on_toggle": "emit('toggle', checked)",
                        "accessibility_role": "switch",
                    }
                },
            }
        ]
        figma_components = [
            {
                "id": "toggle-switch",
                "spatial_hint": {"x": 5, "y": 5, "width": 65, "height": 32},
            }
        ]
        matched = [("toggle-switch", "toggle-switch")]

        result, warnings = merge_spatial(
            original=original,
            figma_components=figma_components,
            matched=matched,
            unmatched_new=[],
            unmatched_original=[],
        )

        output = {c["id"]: c for c in result}
        interaction_behaviors = output["toggle-switch"]["tokens"][
            "Interaction Behaviors"
        ]
        assert interaction_behaviors["on_toggle"] == "emit('toggle', checked)", (
            "SM-2: on_toggle behavioral spec must be unchanged after merge_spatial()"
        )
        assert interaction_behaviors["accessibility_role"] == "switch", (
            "SM-2: accessibility_role behavioral spec must be unchanged after merge_spatial()"
        )


# ---------------------------------------------------------------------------
# SM-3: unmatched Figma-only component added as NEW
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestUnmatchedFigmaNewComponent:
    """SM-3: Figma component not in original added with tag=NEW."""

    def test_SM_3_unmatched_figma_component_added_as_new(self) -> None:
        """SM-3: Given a Figma component not in original (unmatched_new),
        merge_spatial() must include it in output with tag=NEW,
        designer_added=True, and behavioral_spec_status=INCOMPLETE."""
        original: list = []
        figma_components = [
            {
                "id": "hero-banner",
                "spatial_hint": {"x": 0, "y": 0, "width": 1440, "height": 400},
            }
        ]
        unmatched_new = ["hero-banner"]

        result, warnings = merge_spatial(
            original=original,
            figma_components=figma_components,
            matched=[],
            unmatched_new=unmatched_new,
            unmatched_original=[],
        )

        output = {c["id"]: c for c in result}
        assert "hero-banner" in output, (
            "SM-3: unmatched Figma component must appear in merge output"
        )
        component = output["hero-banner"]
        assert component.get("tag") == "NEW", (
            "SM-3: unmatched Figma component must have tag=NEW"
        )
        assert component.get("designer_added") is True, (
            "SM-3: unmatched Figma component must have designer_added=True"
        )
        assert component.get("behavioral_spec_status") == "INCOMPLETE", (
            "SM-3: unmatched Figma component must have behavioral_spec_status=INCOMPLETE"
        )


# ---------------------------------------------------------------------------
# SM-4: unmatched original with INCOMPLETE spec removed silently
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestUnmatchedOriginalIncompleteRemovedSilently:
    """SM-4: Unmatched original with behavioral_spec_status=INCOMPLETE removed without warning."""

    def test_SM_4_incomplete_original_removed_without_warning(self) -> None:
        """SM-4: Given original component not in Figma with
        behavioral_spec_status=INCOMPLETE, merge_spatial() must remove it
        from output without adding a warning string."""
        original = [
            {
                "id": "draft-widget",
                "spatial_hint": {"x": 0, "y": 0, "width": 200, "height": 100},
                "behavioral_spec_status": "INCOMPLETE",
                "tokens": {},
            }
        ]
        unmatched_original = ["draft-widget"]

        result, warnings = merge_spatial(
            original=original,
            figma_components=[],
            matched=[],
            unmatched_new=[],
            unmatched_original=unmatched_original,
        )

        ids = [c["id"] for c in result]
        assert "draft-widget" not in ids, (
            "SM-4: INCOMPLETE unmatched original must be removed from output"
        )
        # No warning should be emitted for INCOMPLETE removals
        for w in warnings:
            assert "draft-widget" not in w, (
                "SM-4: no warning should be produced when removing INCOMPLETE component"
            )


# ---------------------------------------------------------------------------
# SM-5: unmatched original with COMPLETE spec removed with warning
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestUnmatchedOriginalCompleteRemovedWithWarning:
    """SM-5: Unmatched original with behavioral_spec_status=COMPLETE removed with warning."""

    def test_SM_5_complete_original_removed_with_warning(self) -> None:
        """SM-5: Given original component not in Figma with
        behavioral_spec_status=COMPLETE, merge_spatial() must remove it from
        output AND include a warning string in the return value."""
        original = [
            {
                "id": "legacy-nav-bar",
                "spatial_hint": {"x": 0, "y": 0, "width": 1440, "height": 60},
                "behavioral_spec_status": "COMPLETE",
                "tokens": {},
            }
        ]
        unmatched_original = ["legacy-nav-bar"]

        result, warnings = merge_spatial(
            original=original,
            figma_components=[],
            matched=[],
            unmatched_new=[],
            unmatched_original=unmatched_original,
        )

        ids = [c["id"] for c in result]
        assert "legacy-nav-bar" not in ids, (
            "SM-5: COMPLETE unmatched original must be removed from output"
        )
        warning_texts = " ".join(warnings)
        assert "legacy-nav-bar" in warning_texts, (
            "SM-5: a warning string mentioning 'legacy-nav-bar' must be returned "
            "when a COMPLETE component is removed"
        )


# ---------------------------------------------------------------------------
# SM-6: fills and strokes reflect Figma values
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestFillsAndStrokesFromFigma:
    """SM-6: props.fills and props.strokes reflect Figma values after merge."""

    def test_SM_6_fills_and_strokes_updated_from_figma(self) -> None:
        """SM-6: Given components with updated fills/strokes from Figma,
        merge_spatial() must set props.fills and props.strokes to Figma values."""
        original = [
            {
                "id": "card-surface",
                "spatial_hint": {"x": 0, "y": 0, "width": 320, "height": 200},
                "props": {
                    "fills": [{"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0}],
                    "strokes": [],
                },
                "tokens": {},
            }
        ]
        figma_components = [
            {
                "id": "card-surface",
                "spatial_hint": {"x": 0, "y": 0, "width": 320, "height": 200},
                "props": {
                    "fills": [{"r": 0.95, "g": 0.95, "b": 0.98, "a": 1.0}],
                    "strokes": [{"r": 0.8, "g": 0.8, "b": 0.85, "a": 1.0}],
                },
            }
        ]
        matched = [("card-surface", "card-surface")]

        result, warnings = merge_spatial(
            original=original,
            figma_components=figma_components,
            matched=matched,
            unmatched_new=[],
            unmatched_original=[],
        )

        output = {c["id"]: c for c in result}
        props = output["card-surface"]["props"]
        assert props["fills"] == [{"r": 0.95, "g": 0.95, "b": 0.98, "a": 1.0}], (
            "SM-6: props.fills must reflect Figma values"
        )
        assert props["strokes"] == [{"r": 0.8, "g": 0.8, "b": 0.85, "a": 1.0}], (
            "SM-6: props.strokes must reflect Figma values"
        )


# ---------------------------------------------------------------------------
# SM-7: text field reflects Figma characters value
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestTextFieldFromFigma:
    """SM-7: text field reflects Figma characters value after merge."""

    def test_SM_7_text_updated_from_figma_characters(self) -> None:
        """SM-7: Given a component with updated text from Figma,
        merge_spatial() must set the text field to the Figma characters value."""
        original = [
            {
                "id": "cta-label",
                "spatial_hint": {"x": 50, "y": 10, "width": 200, "height": 40},
                "text": "Click here",
                "tokens": {},
            }
        ]
        figma_components = [
            {
                "id": "cta-label",
                "spatial_hint": {"x": 50, "y": 10, "width": 200, "height": 40},
                "characters": "Get started today",
            }
        ]
        matched = [("cta-label", "cta-label")]

        result, warnings = merge_spatial(
            original=original,
            figma_components=figma_components,
            matched=matched,
            unmatched_new=[],
            unmatched_original=[],
        )

        output = {c["id"]: c for c in result}
        assert output["cta-label"]["text"] == "Get started today", (
            "SM-7: text field must reflect Figma characters value"
        )
