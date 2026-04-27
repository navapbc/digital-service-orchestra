"""SVG wireframe generator for figma_merge.

Converts a spatial-layout.json dict into an SVG XML string.

Public interface:
    generate_svg(spatial_layout: dict) -> str

SVG structure follows the ui-designer output-format-reference spec:
  - Root: <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1440 900'>
  - <defs><style>...</style></defs> with CSS classes
  - One <g id='{component.id}'> per component, nested to match JSON hierarchy
  - <rect> inside each <g> using spatial_hint or absoluteBoundingBox
  - tag=NEW  -> class='tag-new'
  - tag=MODIFIED -> class='tag-modified'
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import Any

_SVG_NS = "http://www.w3.org/2000/svg"

_CSS = """
      .container { fill: #E8E8E8; stroke: #CCCCCC; stroke-width: 1; }
      .component { fill: #FFFFFF; stroke: #333333; stroke-width: 1; }
      .interactive { fill: #0066CC; }
      .text-label { font-family: system-ui, sans-serif; font-size: 14px; fill: #333333; }
      .text-heading { font-family: system-ui, sans-serif; font-size: 20px; font-weight: bold; fill: #333333; }
      .text-small { font-family: system-ui, sans-serif; font-size: 11px; fill: #666666; }
      .annotation { font-family: system-ui, sans-serif; font-size: 11px; fill: #666600; font-style: italic; }
      .tag-new { fill: none; stroke: #FF6600; stroke-width: 2; stroke-dasharray: 6 2; }
      .tag-modified { fill: none; stroke: #9933CC; stroke-width: 2; stroke-dasharray: 6 2; }
"""

# Tag -> CSS class mapping (only NEW and MODIFIED get a class)
_TAG_CLASS: dict[str, str] = {
    "NEW": "tag-new",
    "MODIFIED": "tag-modified",
}


def _build_rect(component: dict[str, Any]) -> ET.Element:
    """Build a <rect> element using bounding box info from the component dict."""
    # Prefer absoluteBoundingBox if present, otherwise use defaults
    bbox: dict[str, Any] = component.get("absoluteBoundingBox", {})
    x = str(bbox.get("x", 0))
    y = str(bbox.get("y", 0))
    width = str(bbox.get("width", 100))
    height = str(bbox.get("height", 40))

    rect = ET.Element("rect")
    rect.set("x", x)
    rect.set("y", y)
    rect.set("width", width)
    rect.set("height", height)
    rect.set("class", "component")
    return rect


def _build_group(component: dict[str, Any]) -> ET.Element:
    """Recursively build a <g> element tree for a component and its children."""
    g = ET.Element("g")
    cid = component.get("id", "")
    if cid:
        g.set("id", cid)

    tag = component.get("tag", "EXISTING")
    css_class = _TAG_CLASS.get(tag)
    if css_class:
        g.set("class", css_class)

    # Attach a rect to give the group spatial extent
    g.append(_build_rect(component))

    # Recurse into children
    for child in component.get("children", []):
        g.append(_build_group(child))

    return g


def generate_svg(spatial_layout: dict[str, Any]) -> str:
    """Convert a spatial-layout dict to an SVG XML string.

    Args:
        spatial_layout: Dict parsed from spatial-layout.json.  Must contain
                        at minimum ``storyId``, ``designId``, ``layout``, and
                        ``components`` keys per the output-format-reference spec.

    Returns:
        A UTF-8 SVG XML string (no XML declaration header).
    """
    # Register default namespace so the output uses plain 'svg' not 'ns0:svg'
    ET.register_namespace("", _SVG_NS)

    svg = ET.Element(f"{{{_SVG_NS}}}svg")
    svg.set("viewBox", "0 0 1440 900")

    # <defs><style>...</style></defs>
    defs = ET.SubElement(svg, f"{{{_SVG_NS}}}defs")
    style = ET.SubElement(defs, f"{{{_SVG_NS}}}style")
    style.text = _CSS

    # Render each top-level component (children are nested recursively)
    for component in spatial_layout.get("components", []):
        svg.append(_build_group(component))

    return ET.tostring(svg, encoding="unicode", xml_declaration=False)
