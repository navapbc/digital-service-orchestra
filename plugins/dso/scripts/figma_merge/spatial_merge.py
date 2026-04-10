"""figma_merge.spatial_merge — visual override merge for spatial-layout manifest.

Merges Figma-derived component data with the original spatial-layout manifest,
preserving behavioral specs while overriding visual properties.

Public interface:
    merge_spatial(original, figma_components, matched, unmatched_new,
                  unmatched_original) -> tuple[list, list[str]]
"""

from __future__ import annotations

import copy


def merge_spatial(
    original: list[dict],
    figma_components: list[dict],
    matched: list[tuple[str, str]],
    unmatched_new: list[str],
    unmatched_original: list[str],
) -> tuple[list[dict], list[str]]:
    """Merge Figma-derived visual data with the original spatial-layout manifest.

    For matched components: overrides visual properties (spatial_hint, props.fills,
    props.strokes, text) from Figma while preserving all behavioral specs (tokens).

    For unmatched new (designer-added): adds component with tag=NEW,
    designer_added=True, behavioral_spec_status=INCOMPLETE.

    For unmatched original (designer-removed): removes from output; emits a warning
    string if the removed component had behavioral_spec_status=COMPLETE.

    Args:
        original: List of original manifest component dicts.
        figma_components: List of Figma-derived component dicts.
        matched: List of (figma_id, original_id) tuples for matched pairs.
        unmatched_new: List of Figma component IDs with no original counterpart.
        unmatched_original: List of original component IDs with no Figma counterpart.

    Returns:
        Tuple of (merged_components, warnings) where merged_components is the
        updated list of component dicts and warnings is a list of warning strings
        emitted for COMPLETE behavioral spec removals.
    """
    # Build lookup maps
    original_by_id: dict[str, dict] = {c.get("id", ""): c for c in original}
    figma_by_id: dict[str, dict] = {c.get("id", ""): c for c in figma_components}

    # Build set of original IDs that are removed (unmatched_original)
    removed_ids: set[str] = set(unmatched_original)

    result: list[dict] = []
    warnings: list[str] = []

    # Process matched components
    for figma_id, orig_id in matched:
        orig = original_by_id.get(orig_id)
        figma = figma_by_id.get(figma_id)
        if orig is None or figma is None:
            continue

        # Deep copy to avoid mutating the input
        merged = copy.deepcopy(orig)

        # Override visual: spatial_hint
        if "spatial_hint" in figma:
            merged["spatial_hint"] = copy.deepcopy(figma["spatial_hint"])

        # Override visual: props.fills and props.strokes
        figma_props = figma.get("props", {})
        if figma_props:
            if "props" not in merged:
                merged["props"] = {}
            if "fills" in figma_props:
                merged["props"]["fills"] = copy.deepcopy(figma_props["fills"])
            if "strokes" in figma_props:
                merged["props"]["strokes"] = copy.deepcopy(figma_props["strokes"])

        # Override visual: text from Figma characters field
        if "characters" in figma:
            merged["text"] = figma["characters"]

        # tokens (behavioral specs) are preserved via deep copy of orig — no override

        result.append(merged)

    # Process unmatched new (designer-added)
    for figma_id in unmatched_new:
        figma = figma_by_id.get(figma_id)
        if figma is None:
            continue
        new_comp = copy.deepcopy(figma)
        new_comp["tag"] = "NEW"
        new_comp["designer_added"] = True
        new_comp["behavioral_spec_status"] = "INCOMPLETE"
        result.append(new_comp)

    # Process unmatched original (designer-removed) — emit warnings for COMPLETE
    for orig_id in removed_ids:
        orig = original_by_id.get(orig_id)
        if orig is None:
            continue
        if orig.get("behavioral_spec_status") == "COMPLETE":
            warnings.append(
                f"component '{orig_id}' removed from Figma but had "
                f"behavioral_spec_status=COMPLETE — behavioral specifications may be lost"
            )
        # Component is removed: do not include in result

    return result, warnings
