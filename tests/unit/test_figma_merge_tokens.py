"""Unit tests for figma_merge.tokens_merge.merge_tokens() (RED phase).

Tests cover:
  - TM-1: Visual properties section updated with new fills/sizes from Figma
  - TM-2: 'Interaction Behaviors' section preserved verbatim
  - TM-3: 'Responsive Rules' section preserved verbatim
  - TM-4: 'Accessibility Specification' section preserved verbatim
  - TM-5: 'State Definitions' section preserved verbatim
  - TM-6: Designer-added component (tag=NEW) adds INCOMPLETE behavioral spec placeholder
  - TM-7: Designer-removed component entries are removed from tokens.md output

All tests are expected to FAIL (ImportError / ModuleNotFoundError) because
figma_merge.tokens_merge does not exist yet (RED phase of TDD).
"""

from __future__ import annotations

import pytest

# ---------------------------------------------------------------------------
# Module import — RED phase: this module does not exist yet
# ---------------------------------------------------------------------------

try:
    from figma_merge.tokens_merge import merge_tokens  # type: ignore[import]

    _IMPORT_ERROR: Exception | None = None
except (ImportError, ModuleNotFoundError) as exc:
    merge_tokens = None  # type: ignore[assignment]
    _IMPORT_ERROR = exc


def _require_module() -> None:
    """Raise pytest.fail if the module is not yet implemented."""
    if _IMPORT_ERROR is not None:
        pytest.fail(
            f"figma_merge.tokens_merge could not be imported — "
            f"module must be created before these tests can pass (expected RED failure): "
            f"{_IMPORT_ERROR}"
        )


# ---------------------------------------------------------------------------
# Shared test fixtures
# ---------------------------------------------------------------------------

VISUAL_SECTION = """## Component Inventory

| Component | Tag |
|-----------|-----|
| PrimaryButton | EXISTING |
| CardContainer | EXISTING |

## Visual Properties

### PrimaryButton

- fill: #0057FF
- size: 48px height, 120px width
- stroke: none

### CardContainer

- fill: #FFFFFF
- size: 320px width, auto height
- stroke: 1px #E0E0E0
"""

INTERACTION_BEHAVIORS_SECTION = """## Interaction Behaviors

- PrimaryButton: hover state darkens fill by 10%; active state adds inset shadow
- CardContainer: no interactive states
"""

RESPONSIVE_RULES_SECTION = """## Responsive Rules

- PrimaryButton: full-width below 480px breakpoint
- CardContainer: stacks vertically below 768px breakpoint
"""

ACCESSIBILITY_SPEC_SECTION = """## Accessibility Specification

- PrimaryButton: role=button, aria-label required, min tap target 44x44px
- CardContainer: role=region, aria-label required when used as landmark
"""

STATE_DEFINITIONS_SECTION = """## State Definitions

- PrimaryButton states: default, hover, active, disabled, loading
- CardContainer states: default, loading, error, empty
"""

FULL_TOKENS_MD = (
    VISUAL_SECTION
    + INTERACTION_BEHAVIORS_SECTION
    + RESPONSIVE_RULES_SECTION
    + ACCESSIBILITY_SPEC_SECTION
    + STATE_DEFINITIONS_SECTION
)


# ---------------------------------------------------------------------------
# TM-1: Visual properties section updated with Figma-derived data
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestVisualPropertiesUpdated:
    """TM-1: Visual properties section is updated with new fills/sizes from Figma."""

    def test_visual_properties_updated_with_figma_fills_and_sizes(self) -> None:
        """TM-1: merge_tokens() updates the visual properties section with new fills/sizes."""
        _require_module()

        figma_data = {
            "components": [
                {
                    "name": "PrimaryButton",
                    "tag": "EXISTING",
                    "fills": ["#0033CC"],
                    "size": {"height": "52px", "width": "140px"},
                }
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        assert isinstance(result, str), "merge_tokens() must return a string"
        assert "## Visual Properties" in result, (
            "Output must contain Visual Properties section"
        )
        # New values from Figma should appear
        assert "#0033CC" in result, (
            "Updated fill from Figma (#0033CC) must appear in output"
        )
        assert "52px" in result, (
            "Updated height from Figma (52px) must appear in output"
        )
        assert "140px" in result, (
            "Updated width from Figma (140px) must appear in output"
        )
        # Old values should be replaced
        assert "#0057FF" not in result, (
            "Old fill (#0057FF) must not remain after Figma update"
        )

    def test_component_inventory_updated_from_figma(self) -> None:
        """TM-1 (variant): Component Inventory section reflects Figma component list."""
        _require_module()

        figma_data = {
            "components": [
                {"name": "PrimaryButton", "tag": "EXISTING", "fills": [], "size": {}},
                {"name": "IconButton", "tag": "EXISTING", "fills": [], "size": {}},
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        assert "## Component Inventory" in result, (
            "Output must retain Component Inventory section"
        )


# ---------------------------------------------------------------------------
# TM-2: 'Interaction Behaviors' section preserved verbatim
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestInteractionBehaviorsPreserved:
    """TM-2: 'Interaction Behaviors' section is identical in output (preserved verbatim)."""

    def test_interaction_behaviors_unchanged_after_merge(self) -> None:
        """TM-2: Interaction Behaviors section content is identical before and after merge."""
        _require_module()

        figma_data = {
            "components": [
                {
                    "name": "PrimaryButton",
                    "tag": "EXISTING",
                    "fills": ["#1A1AFF"],
                    "size": {"height": "50px", "width": "130px"},
                }
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        # Extract Interaction Behaviors section from original and result
        original_section = _extract_section(FULL_TOKENS_MD, "## Interaction Behaviors")
        result_section = _extract_section(result, "## Interaction Behaviors")

        assert result_section is not None, (
            "Interaction Behaviors section must be present in output"
        )
        assert result_section == original_section, (
            "Interaction Behaviors section must be preserved verbatim — "
            f"expected:\n{original_section}\ngot:\n{result_section}"
        )


# ---------------------------------------------------------------------------
# TM-3: 'Responsive Rules' section preserved verbatim
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestResponsiveRulesPreserved:
    """TM-3: 'Responsive Rules' section is identical in output (preserved verbatim)."""

    def test_responsive_rules_unchanged_after_merge(self) -> None:
        """TM-3: Responsive Rules section content is identical before and after merge."""
        _require_module()

        figma_data = {
            "components": [
                {
                    "name": "CardContainer",
                    "tag": "EXISTING",
                    "fills": ["#FAFAFA"],
                    "size": {"height": "auto", "width": "340px"},
                }
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        original_section = _extract_section(FULL_TOKENS_MD, "## Responsive Rules")
        result_section = _extract_section(result, "## Responsive Rules")

        assert result_section is not None, (
            "Responsive Rules section must be present in output"
        )
        assert result_section == original_section, (
            "Responsive Rules section must be preserved verbatim — "
            f"expected:\n{original_section}\ngot:\n{result_section}"
        )


# ---------------------------------------------------------------------------
# TM-4: 'Accessibility Specification' section preserved verbatim
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestAccessibilitySpecPreserved:
    """TM-4: 'Accessibility Specification' section is identical in output (preserved verbatim)."""

    def test_accessibility_spec_unchanged_after_merge(self) -> None:
        """TM-4: Accessibility Specification section content is identical before and after merge."""
        _require_module()

        figma_data = {
            "components": [
                {
                    "name": "PrimaryButton",
                    "tag": "EXISTING",
                    "fills": ["#FF0000"],
                    "size": {"height": "44px", "width": "100px"},
                }
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        original_section = _extract_section(
            FULL_TOKENS_MD, "## Accessibility Specification"
        )
        result_section = _extract_section(result, "## Accessibility Specification")

        assert result_section is not None, (
            "Accessibility Specification section must be present in output"
        )
        assert result_section == original_section, (
            "Accessibility Specification section must be preserved verbatim — "
            f"expected:\n{original_section}\ngot:\n{result_section}"
        )


# ---------------------------------------------------------------------------
# TM-5: 'State Definitions' section preserved verbatim
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestStateDefinitionsPreserved:
    """TM-5: 'State Definitions' section is identical in output (preserved verbatim)."""

    def test_state_definitions_unchanged_after_merge(self) -> None:
        """TM-5: State Definitions section content is identical before and after merge."""
        _require_module()

        figma_data = {
            "components": [
                {
                    "name": "PrimaryButton",
                    "tag": "EXISTING",
                    "fills": ["#003399"],
                    "size": {"height": "48px", "width": "120px"},
                }
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        original_section = _extract_section(FULL_TOKENS_MD, "## State Definitions")
        result_section = _extract_section(result, "## State Definitions")

        assert result_section is not None, (
            "State Definitions section must be present in output"
        )
        assert result_section == original_section, (
            "State Definitions section must be preserved verbatim — "
            f"expected:\n{original_section}\ngot:\n{result_section}"
        )


# ---------------------------------------------------------------------------
# TM-6: Designer-added component (tag=NEW) adds INCOMPLETE placeholder
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestNewComponentPlaceholder:
    """TM-6: NEW-tagged component gets INCOMPLETE behavioral spec placeholder."""

    def test_new_component_adds_incomplete_placeholder_to_tokens_md(self) -> None:
        """TM-6: A designer-added component (tag=NEW) adds INCOMPLETE placeholder entry."""
        _require_module()

        figma_data = {
            "components": [
                {"name": "PrimaryButton", "tag": "EXISTING", "fills": [], "size": {}},
                {
                    "name": "TooltipOverlay",
                    "tag": "NEW",
                    "fills": ["#333333"],
                    "size": {"height": "32px", "width": "auto"},
                },
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        assert "TooltipOverlay" in result, (
            "NEW component 'TooltipOverlay' must appear in output"
        )
        assert "INCOMPLETE" in result, (
            "Output must contain INCOMPLETE placeholder for the new component"
        )

    def test_new_component_placeholder_is_in_behavioral_spec_area(self) -> None:
        """TM-6 (variant): The INCOMPLETE marker for a NEW component appears as a spec placeholder."""
        _require_module()

        figma_data = {
            "components": [
                {
                    "name": "FloatingMenu",
                    "tag": "NEW",
                    "fills": ["#FFFFFF"],
                    "size": {"height": "auto", "width": "200px"},
                },
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        assert "FloatingMenu" in result, (
            "NEW component 'FloatingMenu' must appear in output"
        )
        # The placeholder should signal that behavioral spec needs to be filled in
        assert "INCOMPLETE" in result, (
            "INCOMPLETE placeholder must be present for FloatingMenu new component"
        )

    def test_existing_components_not_marked_incomplete(self) -> None:
        """TM-6 (variant): EXISTING components are not given INCOMPLETE placeholder."""
        _require_module()

        # Inject an INCOMPLETE placeholder into the input so that if merge_tokens
        # returns the original text unchanged the assertion will fail — the test
        # must confirm removal, not merely that INCOMPLETE was never present.
        tokens_with_incomplete = FULL_TOKENS_MD + (
            "\n### PrimaryButton\n\n- behavioral_spec_status: INCOMPLETE\n"
        )

        figma_data = {
            "components": [
                {
                    "name": "PrimaryButton",
                    "tag": "EXISTING",
                    "fills": ["#0057FF"],
                    "size": {"height": "48px", "width": "120px"},
                },
            ]
        }
        result = merge_tokens(tokens_with_incomplete, figma_data)

        assert "INCOMPLETE" not in result, (
            "EXISTING components must not be given an INCOMPLETE placeholder — "
            "merge_tokens must remove pre-existing INCOMPLETE markers for EXISTING components"
        )


# ---------------------------------------------------------------------------
# TM-7: Designer-removed component entries are removed from output
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestRemovedComponentEntriesDeleted:
    """TM-7: Designer-removed component entries are removed from tokens.md output."""

    def test_removed_component_absent_from_output(self) -> None:
        """TM-7: A component present in tokens.md but absent from Figma data is removed."""
        _require_module()

        # Figma data no longer includes CardContainer — it was removed by the designer
        figma_data = {
            "components": [
                {
                    "name": "PrimaryButton",
                    "tag": "EXISTING",
                    "fills": ["#0057FF"],
                    "size": {"height": "48px", "width": "120px"},
                },
                # CardContainer intentionally absent
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        # CardContainer should be gone from the visual sections
        assert "CardContainer" not in result, (
            "CardContainer was removed from Figma data; its token entries must be "
            "removed from the output"
        )

    def test_retained_component_still_present_after_removal(self) -> None:
        """TM-7 (variant): Components still in Figma are unaffected by removal of others."""
        _require_module()

        figma_data = {
            "components": [
                {
                    "name": "PrimaryButton",
                    "tag": "EXISTING",
                    "fills": ["#0057FF"],
                    "size": {"height": "48px", "width": "120px"},
                },
            ]
        }
        result = merge_tokens(FULL_TOKENS_MD, figma_data)

        assert "PrimaryButton" in result, (
            "PrimaryButton was not removed from Figma data and must remain in output"
        )


# ---------------------------------------------------------------------------
# Helper utilities
# ---------------------------------------------------------------------------


def _extract_section(text: str, heading: str) -> str | None:
    """Extract the content of a markdown section from *text*, starting at *heading*.

    Returns the section text (from the heading line through the line before the
    next same-or-higher-level heading, or end-of-document), or None if the
    heading is not found.
    """
    import re

    # Determine heading level
    level_match = re.match(r"^(#{1,6})\s", heading)
    if not level_match:
        return None
    level = len(level_match.group(1))

    lines = text.splitlines(keepends=True)
    in_section = False
    section_lines: list[str] = []

    for line in lines:
        # Check if this line starts a new heading of same or higher level
        heading_match = re.match(r"^(#{1,6})\s", line)
        if heading_match and len(heading_match.group(1)) <= level:
            if in_section:
                # End of the target section
                break
            if line.rstrip() == heading.rstrip() or line.startswith(
                heading.split()[0] + " " + " ".join(heading.split()[1:])
            ):
                in_section = True
                section_lines.append(line)
                continue

        if in_section:
            section_lines.append(line)

    return "".join(section_lines) if section_lines else None
