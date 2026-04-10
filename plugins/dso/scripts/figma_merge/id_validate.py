"""figma_merge.id_validate — validate component ID linkage across design artifacts.

Checks that component IDs in spatial-layout.json are consistently reflected in
wireframe.svg (<g id=...> elements) and tokens.md (text references), and that
no orphaned IDs exist in wireframe.svg without a corresponding spatial component.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET


def _extract_spatial_ids(spatial_layout: dict) -> list[str]:
    """Recursively extract all component IDs from spatial_layout['components']."""
    ids: list[str] = []
    components = spatial_layout.get("components", [])
    stack = list(components)
    while stack:
        component = stack.pop()
        cid = component.get("id")
        if cid is not None:
            ids.append(cid)
        # Handle nested components
        nested = component.get("components", [])
        stack.extend(nested)
    return ids


def _extract_svg_g_ids(svg_content: str) -> list[str]:
    """Extract id attributes from all <g> elements in the SVG."""
    ids: list[str] = []
    try:
        root = ET.fromstring(svg_content)
    except ET.ParseError:
        return ids

    # ElementTree strips namespace prefixes; search all elements named 'g'
    # Try with namespace first
    for elem in root.iter("{http://www.w3.org/2000/svg}g"):
        eid = elem.get("id")
        if eid is not None:
            ids.append(eid)
    # Also try without namespace (in case SVG has no namespace declaration)
    for elem in root.iter("g"):
        eid = elem.get("id")
        if eid is not None and eid not in ids:
            ids.append(eid)
    return ids


def _extract_tokens_referenced_ids(
    tokens_md: str, candidate_ids: list[str]
) -> set[str]:
    """Return the subset of candidate_ids that appear anywhere in tokens_md."""
    referenced: set[str] = set()
    for cid in candidate_ids:
        # Use word-boundary-like check: the ID must appear as a recognizable token.
        # Word boundaries ensure 'btn' does not match inside 'btn-primary'.
        pattern = r"\b" + re.escape(cid) + r"\b"
        if re.search(pattern, tokens_md):
            referenced.add(cid)
    return referenced


def validate_id_linkage(
    spatial_layout: dict,
    svg_content: str,
    tokens_md: str,
) -> list[dict]:
    """Validate component ID linkage across spatial-layout.json, wireframe.svg, and tokens.md.

    Args:
        spatial_layout: Parsed spatial-layout.json dict (must have 'components' key).
        svg_content: Raw SVG XML string for wireframe.svg.
        tokens_md: Raw Markdown string for tokens.md.

    Returns:
        List of violation dicts, each with keys:
            - id (str): The component ID involved.
            - artifact (str): The artifact where the violation was detected.
            - violation_type (str): 'missing' or 'orphaned'.
        An empty list indicates clean linkage.
    """
    violations: list[dict] = []

    spatial_ids = _extract_spatial_ids(spatial_layout)
    spatial_id_set = set(spatial_ids)

    svg_g_ids = _extract_svg_g_ids(svg_content)
    svg_g_id_set = set(svg_g_ids)

    # All IDs that appear anywhere (for tokens reference check)
    all_candidate_ids = list(spatial_id_set | svg_g_id_set)
    tokens_referenced = _extract_tokens_referenced_ids(tokens_md, all_candidate_ids)

    # Check each spatial ID against wireframe and tokens
    for sid in spatial_ids:
        if sid not in svg_g_id_set:
            violations.append(
                {
                    "id": sid,
                    "artifact": "wireframe.svg",
                    "violation_type": "missing",
                }
            )
        if sid not in tokens_referenced:
            violations.append(
                {
                    "id": sid,
                    "artifact": "tokens.md",
                    "violation_type": "missing",
                }
            )

    # Check for orphaned SVG <g> IDs (in wireframe but not in spatial)
    for gid in svg_g_ids:
        if gid not in spatial_id_set:
            violations.append(
                {
                    "id": gid,
                    "artifact": "wireframe.svg",
                    "violation_type": "orphaned",
                }
            )

    return violations
