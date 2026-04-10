#!/usr/bin/env python3
"""Figma JSON tree → spatial-layout.json mapper.

CLI usage:
    python3 figma_node_mapper.py <input_file> <output_file>

Module usage:
    from figma_node_mapper import map_nodes, identity_match
    components = map_nodes(figma_json, depth_limit=20)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def _collect_component_ids(node: dict, component_ids: set) -> None:
    """First-pass traversal to collect all component IDs and names for linking."""
    if node.get("type") == "COMPONENT":
        cid = node.get("componentId") or node.get("id", "")
        if cid:
            component_ids.add(cid)
        name = node.get("name", "")
        if name:
            component_ids.add(name)
    for child in node.get("children", []):
        _collect_component_ids(child, component_ids)


def _map_single_node(node: dict, node_type: str, component_ids: set) -> dict:
    """Map a single Figma node to a component dict (without children traversal)."""
    node_id = node.get("id", "")
    node_name = node.get("name", "")

    component: dict[str, Any] = {
        "id": node_id,
        "name": node_name,
    }

    # Spatial hint from absoluteBoundingBox
    bbox = node.get("absoluteBoundingBox")
    if bbox:
        component["spatial_hint"] = {
            "x": bbox.get("x", 0),
            "y": bbox.get("y", 0),
            "width": bbox.get("width", 0),
            "height": bbox.get("height", 0),
        }

    if node_type in ("FRAME", "GROUP"):
        component["type"] = "Section"

    elif node_type == "TEXT":
        component["type"] = "TextNode"
        chars = node.get("characters", "")
        component["text"] = chars
        component["text_content"] = chars
        component["characters"] = chars

    elif node_type in ("RECTANGLE", "VECTOR"):
        component["type"] = "Shape"
        props: dict[str, Any] = {}
        if "fills" in node:
            props["fills"] = node["fills"]
        if "strokes" in node:
            props["strokes"] = node["strokes"]
        component["props"] = props

    elif node_type == "COMPONENT":
        component["type"] = "Component"
        component_id = node.get("componentId", "")
        if component_id:
            component["componentId"] = component_id
        component["behavioral_spec_placeholder"] = (
            "TODO: define behavioral spec for this component"
        )

    elif node_type == "INSTANCE":
        component["type"] = "Instance"
        component["is_instance"] = True
        component["node_type"] = "INSTANCE"
        ref = node.get("componentId") or node.get("componentSetId") or node_name
        component["component_ref"] = ref
        component["instance_of"] = ref
        component["source_component_id"] = ref

    else:
        component["type"] = "Unknown"

    # Name-based component linking: non-COMPONENT nodes whose name matches a known
    # component id are linked to it.
    if node_name in component_ids and node_type != "COMPONENT":
        component["link_to"] = node_name
        component["linked_component"] = node_name

    return component


def map_nodes(figma_json: dict, depth_limit: int = 20) -> list[dict]:
    """Traverse Figma document tree and return flat list of mapped components.

    Args:
        figma_json: Parsed Figma file JSON (must have 'document' key)
        depth_limit: Maximum node depth to traverse (default 20)

    Returns:
        Flat list of component dicts
    """
    results: list[dict] = []

    document = figma_json.get("document", {})

    # First pass: collect all component IDs for name-based linking
    component_ids: set[str] = set()
    _collect_component_ids(document, component_ids)

    def _traverse(node: dict, depth: int) -> None:
        if depth > depth_limit:
            return

        node_type = node.get("type", "UNKNOWN")

        if node_type == "DOCUMENT":
            # Traverse children without adding the DOCUMENT node itself
            for child in node.get("children", []):
                _traverse(child, depth + 1)
            return

        component = _map_single_node(node, node_type, component_ids)
        results.append(component)

        for child in node.get("children", []):
            _traverse(child, depth + 1)

    _traverse(document, 0)
    return results


def identity_match(
    figma_nodes: list[dict],
    original_manifest: dict,
) -> tuple[dict, list[dict], list[dict]]:
    """Match Figma nodes to original manifest components.

    Primary matching: Figma node name → original component id.
    Fallback: structural position (index in flat list).

    Args:
        figma_nodes: List of mapped Figma node components
        original_manifest: Original spatial-layout manifest dict

    Returns:
        Tuple of (matched_map, unmatched_new, unmatched_original) where:
        - matched_map: {figma_node_id: original_component_id}
        - unmatched_new: Figma nodes with no original match (flagged unmatched_new=True)
        - unmatched_original: Original components with no Figma match (flagged unmatched_original=True)
    """
    original_components = original_manifest.get("components", [])
    original_by_id = {c.get("id", ""): c for c in original_components}

    matched_map: dict[str, str] = {}
    unmatched_new: list[dict] = []
    matched_original_ids: set[str] = set()

    for idx, node in enumerate(figma_nodes):
        node_id = node.get("id", "")
        node_name = node.get("name", "")

        # Primary: match by name to original component id
        matched = False
        for orig_id, orig_comp in original_by_id.items():
            if orig_id == node_name or orig_comp.get("name") == node_name:
                matched_map[node_id] = orig_id
                matched_original_ids.add(orig_id)
                matched = True
                break

        if not matched:
            # Fallback: structural position match
            if idx < len(original_components):
                orig_comp = original_components[idx]
                orig_id = orig_comp.get("id", "")
                matched_map[node_id] = orig_id
                matched_original_ids.add(orig_id)
            else:
                node_copy = dict(node)
                node_copy["unmatched_new"] = True
                unmatched_new.append(node_copy)

    unmatched_original: list[dict] = []
    for comp in original_components:
        if comp.get("id", "") not in matched_original_ids:
            comp_copy = dict(comp)
            comp_copy["unmatched_original"] = True
            unmatched_original.append(comp_copy)

    return matched_map, unmatched_new, unmatched_original


def main() -> int:
    """CLI entry point: python3 figma_node_mapper.py <input_file> <output_file>"""
    if len(sys.argv) < 3:
        print(
            f"Usage: {sys.argv[0]} <input_file> <output_file>",
            file=sys.stderr,
        )
        return 1

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])

    try:
        with open(input_path) as f:
            figma_json = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error: invalid JSON in {input_path}: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"Error: cannot read {input_path}: {e}", file=sys.stderr)
        return 1

    components = map_nodes(figma_json)

    output = {
        "metadata": {
            "source": "figma",
            "figma_name": figma_json.get("name", ""),
            "last_modified": figma_json.get("lastModified", ""),
            "version": str(figma_json.get("version", "")),
        },
        "components": components,
    }

    try:
        with open(output_path, "w") as f:
            json.dump(output, f, indent=2)
    except OSError as e:
        print(f"Error: cannot write {output_path}: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
