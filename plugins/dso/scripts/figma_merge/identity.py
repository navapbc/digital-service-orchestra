"""figma_merge.identity — identity matching for Figma node merge.

Provides :func:`identity_match` which maps Figma nodes to original manifest
components by name (primary) or structural position (fallback).
"""

from __future__ import annotations


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
