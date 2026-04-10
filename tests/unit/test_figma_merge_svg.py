"""Unit tests for figma_merge.svg_gen.generate_svg() (RED phase).

Tests cover:
  - SG-1: generate_svg() returns valid XML with an <svg> root element
  - SG-2: Component with id='comp-1' produces <g id='comp-1'> in output
  - SG-3: Component with tag=NEW produces <g> with class='tag-new'
  - SG-4: Component with tag=MODIFIED produces <g> with class='tag-modified'
  - SG-5: Parent-child nesting produces nested <g> elements
  - SG-6: Removed component (absent from JSON) has no <g> element in output
  - SG-7: Every component ID in the JSON has a corresponding <g id=...> in the SVG

All tests are expected to FAIL (ImportError / ModuleNotFoundError) because
figma_merge.svg_gen does not exist yet (RED phase of TDD).
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import pytest

# Add the scripts directory so `figma_merge` package is importable.
_SCRIPTS_DIR = str(Path(__file__).resolve().parents[2] / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# ---------------------------------------------------------------------------
# Module import — expected to fail in RED phase
# ---------------------------------------------------------------------------
from figma_merge.svg_gen import generate_svg  # noqa: E402  # RED: module not implemented


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

SVG_NS = "http://www.w3.org/2000/svg"


def _parse_svg(svg_text: str) -> ET.Element:
    """Parse SVG string into an ElementTree root element."""
    return ET.fromstring(svg_text)


def _find_g_by_id(root: ET.Element, element_id: str) -> ET.Element | None:
    """Return the first <g> element with the given id attribute, or None."""
    # Search with and without namespace prefix
    for elem in root.iter():
        tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
        if tag == "g" and elem.attrib.get("id") == element_id:
            return elem
    return None


def _all_g_ids(root: ET.Element) -> set[str]:
    """Return the set of all id attributes on <g> elements in the tree."""
    ids: set[str] = set()
    for elem in root.iter():
        tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
        if tag == "g":
            g_id = elem.attrib.get("id")
            if g_id:
                ids.add(g_id)
    return ids


def _collect_ids(components: list[dict[str, Any]]) -> list[str]:
    """Recursively collect all component IDs from a spatial-layout components list."""
    ids: list[str] = []
    for comp in components:
        ids.append(comp["id"])
        ids.extend(_collect_ids(comp.get("children", [])))
    return ids


# ---------------------------------------------------------------------------
# SG-1: Valid XML with <svg> root element
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestSG1ValidSvgRoot:
    """SG-1: Given a spatial-layout.json with one component having spatial_hint bounds,
    when generate_svg() runs, then output is valid XML with an <svg> root element.
    """

    def test_sg1_output_is_valid_xml_with_svg_root(self) -> None:
        """SG-1: generate_svg output is valid XML with <svg> root."""
        spatial_layout = {
            "storyId": "test-001",
            "designId": "00000000-0000-0000-0000-000000000001",
            "layout": "SinglePanel",
            "components": [
                {
                    "id": "main-panel",
                    "type": "Panel",
                    "tag": "EXISTING",
                    "spatial_hint": "Full-width, centered",
                }
            ],
        }

        result = generate_svg(spatial_layout)

        assert isinstance(result, str), "generate_svg must return a string"
        root = _parse_svg(result)
        root_tag = root.tag.split("}")[-1] if "}" in root.tag else root.tag
        assert root_tag == "svg", f"Root element must be <svg>, got <{root_tag}>"


# ---------------------------------------------------------------------------
# SG-2: Component id maps to <g id='comp-1'>
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestSG2ComponentIdInG:
    """SG-2: Given a component with id='comp-1' and spatial_hint bounds,
    when generate_svg() runs, then output contains <g id='comp-1'>.
    """

    def test_sg2_component_id_appears_in_g_element(self) -> None:
        """SG-2: Component id='comp-1' produces <g id='comp-1'> in SVG output."""
        spatial_layout = {
            "storyId": "test-002",
            "designId": "00000000-0000-0000-0000-000000000002",
            "layout": "SinglePanel",
            "components": [
                {
                    "id": "comp-1",
                    "type": "Button",
                    "tag": "EXISTING",
                    "spatial_hint": "Top-right, 24px margin",
                }
            ],
        }

        result = generate_svg(spatial_layout)
        root = _parse_svg(result)

        g_elem = _find_g_by_id(root, "comp-1")
        assert g_elem is not None, (
            "SVG output must contain <g id='comp-1'> for a component with id='comp-1'"
        )


# ---------------------------------------------------------------------------
# SG-3: tag=NEW component gets class='tag-new'
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestSG3TagNewClass:
    """SG-3: Given a component with tag=NEW,
    when generate_svg() runs, then its <g> element has class='tag-new'.
    """

    def test_sg3_new_component_g_has_tag_new_class(self) -> None:
        """SG-3: Component with tag=NEW produces <g class='tag-new'>."""
        spatial_layout = {
            "storyId": "test-003",
            "designId": "00000000-0000-0000-0000-000000000003",
            "layout": "SinglePanel",
            "components": [
                {
                    "id": "new-component",
                    "type": "FilterChip",
                    "tag": "NEW",
                    "justification": "No existing component matches",
                    "spatial_hint": "Below header, left-aligned",
                }
            ],
        }

        result = generate_svg(spatial_layout)
        root = _parse_svg(result)

        g_elem = _find_g_by_id(root, "new-component")
        assert g_elem is not None, "SVG must contain <g id='new-component'>"
        css_class = g_elem.attrib.get("class", "")
        assert "tag-new" in css_class, (
            f"<g id='new-component'> must have class='tag-new', got class='{css_class}'"
        )


# ---------------------------------------------------------------------------
# SG-4: tag=MODIFIED component gets class='tag-modified'
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestSG4TagModifiedClass:
    """SG-4: Given a component with tag=MODIFIED,
    when generate_svg() runs, then its <g> element has class='tag-modified'.
    """

    def test_sg4_modified_component_g_has_tag_modified_class(self) -> None:
        """SG-4: Component with tag=MODIFIED produces <g class='tag-modified'>."""
        spatial_layout = {
            "storyId": "test-004",
            "designId": "00000000-0000-0000-0000-000000000004",
            "layout": "SinglePanel",
            "components": [
                {
                    "id": "modified-button",
                    "type": "Button",
                    "tag": "MODIFIED",
                    "design_system_ref": "Components/Button",
                    "modification_notes": "Add loading spinner variant",
                    "spatial_hint": "Bottom-right, 16px margin",
                }
            ],
        }

        result = generate_svg(spatial_layout)
        root = _parse_svg(result)

        g_elem = _find_g_by_id(root, "modified-button")
        assert g_elem is not None, "SVG must contain <g id='modified-button'>"
        css_class = g_elem.attrib.get("class", "")
        assert "tag-modified" in css_class, (
            f"<g id='modified-button'> must have class='tag-modified', got class='{css_class}'"
        )


# ---------------------------------------------------------------------------
# SG-5: Parent-child nesting in components produces nested <g> elements
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestSG5ParentChildNesting:
    """SG-5: Given components with parent-child nesting,
    when generate_svg() runs, then child components are nested inside parent <g> elements.
    """

    def test_sg5_child_g_nested_inside_parent_g(self) -> None:
        """SG-5: Child component <g> is nested inside parent component <g>."""
        spatial_layout = {
            "storyId": "test-005",
            "designId": "00000000-0000-0000-0000-000000000005",
            "layout": "Sidebar-Content",
            "components": [
                {
                    "id": "parent-section",
                    "type": "Section",
                    "tag": "EXISTING",
                    "spatial_hint": "Full-width container",
                    "children": [
                        {
                            "id": "child-button",
                            "type": "Button",
                            "tag": "EXISTING",
                            "spatial_hint": "Top-right within parent",
                        }
                    ],
                }
            ],
        }

        result = generate_svg(spatial_layout)
        root = _parse_svg(result)

        parent_g = _find_g_by_id(root, "parent-section")
        assert parent_g is not None, "SVG must contain <g id='parent-section'>"

        # Child should be nested inside the parent <g>
        child_g = None
        for elem in parent_g.iter():
            tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
            if tag == "g" and elem.attrib.get("id") == "child-button":
                child_g = elem
                break

        assert child_g is not None, (
            "<g id='child-button'> must be nested inside <g id='parent-section'>, "
            "not at the top level"
        )


# ---------------------------------------------------------------------------
# SG-6: Removed component (absent from JSON) has no <g> in SVG
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestSG6RemovedComponentAbsent:
    """SG-6: Given a spatial-layout.json where a component was removed (not present),
    when generate_svg() runs, then no <g> element with the removed component's id appears.
    """

    def test_sg6_absent_component_has_no_g_element(self) -> None:
        """SG-6: Component not in JSON produces no <g> element in SVG."""
        spatial_layout = {
            "storyId": "test-006",
            "designId": "00000000-0000-0000-0000-000000000006",
            "layout": "SinglePanel",
            "components": [
                {
                    "id": "present-component",
                    "type": "Header",
                    "tag": "EXISTING",
                    "spatial_hint": "Top, full-width",
                }
                # 'removed-component' is intentionally absent
            ],
        }

        result = generate_svg(spatial_layout)
        root = _parse_svg(result)

        removed_g = _find_g_by_id(root, "removed-component")
        assert removed_g is None, (
            "SVG must NOT contain <g id='removed-component'> because that component "
            "was not present in the spatial-layout.json"
        )


# ---------------------------------------------------------------------------
# SG-7: Every component ID in the JSON has a <g id=...> in the SVG
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestSG7AllComponentIdsPresent:
    """SG-7: Given the output SVG, when cross-referenced with spatial-layout.json component IDs,
    then every component ID in the JSON has a corresponding <g id=...> in the SVG.
    """

    def test_sg7_all_json_component_ids_have_g_elements(self) -> None:
        """SG-7: All component IDs in spatial-layout.json map to <g id=...> in SVG."""
        spatial_layout = {
            "storyId": "test-007",
            "designId": "00000000-0000-0000-0000-000000000007",
            "layout": "TopNav-Sidebar-Main",
            "components": [
                {
                    "id": "nav-bar",
                    "type": "NavBar",
                    "tag": "EXISTING",
                    "spatial_hint": "Top, full-width, 64px height",
                    "children": [
                        {
                            "id": "nav-logo",
                            "type": "Logo",
                            "tag": "EXISTING",
                            "spatial_hint": "Left-aligned, 40px",
                        },
                        {
                            "id": "nav-search",
                            "type": "SearchInput",
                            "tag": "MODIFIED",
                            "design_system_ref": "Components/Forms/SearchInput",
                            "modification_notes": "Add voice search icon",
                            "spatial_hint": "Center, max-width 400px",
                        },
                    ],
                },
                {
                    "id": "main-content",
                    "type": "Section",
                    "tag": "EXISTING",
                    "spatial_hint": "Below nav, flex-grow",
                    "children": [
                        {
                            "id": "action-button",
                            "type": "Button",
                            "tag": "NEW",
                            "justification": "Custom CTA not in design system",
                            "spatial_hint": "Bottom-right, 24px margin",
                        }
                    ],
                },
            ],
        }

        result = generate_svg(spatial_layout)
        root = _parse_svg(result)

        all_json_ids = _collect_ids(spatial_layout["components"])
        svg_g_ids = _all_g_ids(root)

        missing = [cid for cid in all_json_ids if cid not in svg_g_ids]
        assert not missing, (
            f"The following component IDs from spatial-layout.json are missing "
            f"from the SVG as <g id=...> elements: {missing}"
        )
