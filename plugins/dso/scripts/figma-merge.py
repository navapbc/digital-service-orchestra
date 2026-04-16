#!/usr/bin/env python3
"""figma-merge.py — CLI entry point for the Figma design manifest merge workflow.

Orchestrates the full pull-back pipeline: loads original manifest artifacts,
merges Figma-derived visual changes while preserving behavioral specs, validates
ID-linkage, and writes updated artifacts to disk.

Emits FIGMA_MERGE_OUTPUT JSON to stdout on success and error.
See: docs/contracts/figma-merge-output.md

Usage:
    python3 figma-merge.py \\
        --manifest-dir <dir>       # directory with spatial-layout.json, wireframe.svg, tokens.md
        --revised-spatial <file>   # Figma-derived spatial JSON (output of figma-node-mapper.py)
        [--output-dir <dir>]       # output directory (defaults to --manifest-dir)
        [--non-interactive]        # skip confirmation prompt; proceed and emit warnings to stderr
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Make the figma_merge package importable when run as a script
_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from figma_merge.identity import identity_match  # noqa: E402
from figma_merge.id_validate import validate_id_linkage  # noqa: E402
from figma_merge.spatial_merge import merge_spatial  # noqa: E402
from figma_merge.svg_gen import generate_svg  # noqa: E402
from figma_merge.tokens_merge import merge_tokens  # noqa: E402


def _load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _load_text(path: Path) -> str:
    with path.open("r", encoding="utf-8") as f:
        return f.read()


def _write_json(path: Path, data: dict) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def _write_text(path: Path, content: str) -> None:
    with path.open("w", encoding="utf-8") as f:
        f.write(content)


def _emit_output(
    status: str,
    components_added: int = 0,
    components_modified: int = 0,
    components_removed: int = 0,
    behavioral_specs_preserved: int = 0,
    warnings: list[str] | None = None,
    error_message: str | None = None,
) -> None:
    """Emit FIGMA_MERGE_OUTPUT JSON to stdout (contract: figma-merge-output.md)."""
    payload: dict = {
        "status": status,
        "components_added": components_added,
        "components_modified": components_modified,
        "components_removed": components_removed,
        "behavioral_specs_preserved": behavioral_specs_preserved,
        "warnings": warnings or [],
    }
    if error_message is not None:
        payload["error_message"] = error_message
    print(json.dumps(payload))


def _count_visual_modifications(
    matched: list[tuple[str, str]],
    original_by_id: dict[str, dict],
    figma_by_id: dict[str, dict],
) -> int:
    """Count matched components where at least one visual field changed."""
    modified = 0
    for figma_id, orig_id in matched:
        orig = original_by_id.get(orig_id, {})
        figma = figma_by_id.get(figma_id, {})
        changed = False
        if "spatial_hint" in figma and figma["spatial_hint"] != orig.get(
            "spatial_hint"
        ):
            changed = True
        if not changed:
            figma_props = figma.get("props", {})
            orig_props = orig.get("props", {})
            if "fills" in figma_props and figma_props["fills"] != orig_props.get(
                "fills"
            ):
                changed = True
            if (
                not changed
                and "strokes" in figma_props
                and figma_props["strokes"] != orig_props.get("strokes")
            ):
                changed = True
        if (
            not changed
            and "characters" in figma
            and figma["characters"] != orig.get("characters")
        ):
            changed = True
        if changed:
            modified += 1
    return modified


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    """Parse CLI arguments for figma-merge."""
    parser = argparse.ArgumentParser(
        description="Merge Figma-revised spatial layout into existing manifest artifacts."
    )
    parser.add_argument(
        "--manifest-dir",
        required=True,
        help="Directory containing spatial-layout.json, wireframe.svg, and tokens.md",
    )
    parser.add_argument(
        "--revised-spatial",
        required=True,
        help="Path to Figma-derived spatial-layout JSON (figma-revised-spatial.json)",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Output directory for merged artifacts (defaults to --manifest-dir)",
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Skip confirmation prompt; emit warnings to stderr and proceed",
    )
    return parser.parse_args(argv)


def _load_inputs(
    manifest_dir: Path, revised_spatial_path: Path
) -> tuple[dict, str, str, dict, list[dict], list[dict]]:
    """Load all input artifacts and return (original_spatial, svg, tokens, figma_revised, figma_components, original_components)."""
    original_spatial = _load_json(manifest_dir / "spatial-layout.json")
    original_svg = _load_text(manifest_dir / "wireframe.svg")
    original_tokens_md = _load_text(manifest_dir / "tokens.md")
    figma_revised = _load_json(revised_spatial_path)
    figma_components: list[dict] = figma_revised.get("components", [])
    original_components: list[dict] = original_spatial.get("components", [])
    return (
        original_spatial,
        original_svg,
        original_tokens_md,
        figma_revised,
        figma_components,
        original_components,
    )


def _run_merge_pipeline(
    original_spatial: dict,
    original_svg: str,
    original_tokens_md: str,
    figma_components: list[dict],
    original_components: list[dict],
    non_interactive: bool,
) -> tuple[int, list[dict], list[str], list[tuple[str, str]], list[str], list[str]]:
    """Run the component matching, merging, and interactive confirmation.

    Returns (exit_code, merged_components, warnings, matched, unmatched_new_ids, unmatched_original_ids).
    Exit code 1 means abort; 0 means proceed.
    """
    # Pre-flight: validate input artifact consistency
    input_violations = validate_id_linkage(
        original_spatial, original_svg, original_tokens_md
    )
    if input_violations:
        for v in input_violations:
            print(
                f"ERROR: Input ID-linkage violation — id='{v.get('id')}' "
                f"artifact='{v.get('artifact')}' type='{v.get('violation_type')}'",
                file=sys.stderr,
            )
        _emit_output(
            "error",
            error_message="Input ID-linkage violation detected — see stderr for details",
        )
        return 1, [], [], [], [], []

    # Match components
    matched_map, unmatched_new_nodes, unmatched_original_nodes = identity_match(
        figma_nodes=figma_components,
        original_manifest=original_spatial,
    )
    matched: list[tuple[str, str]] = list(matched_map.items())
    unmatched_new_ids: list[str] = [n.get("id", "") for n in unmatched_new_nodes]
    unmatched_original_ids: list[str] = [
        c.get("id", "") for c in unmatched_original_nodes
    ]

    # Merge spatial
    merged_components, warnings = merge_spatial(
        original=original_components,
        figma_components=figma_components,
        matched=matched,
        unmatched_new=unmatched_new_ids,
        unmatched_original=unmatched_original_ids,
    )

    # Emit warnings
    for w in warnings:
        print(f"WARN: {w}", file=sys.stderr)

    # Confirmation (interactive only)
    if not non_interactive and (
        warnings or unmatched_new_ids or unmatched_original_ids
    ):
        change_summary = []
        if unmatched_new_ids:
            change_summary.append(
                f"  + {len(unmatched_new_ids)} designer-added component(s): {', '.join(unmatched_new_ids)}"
            )
        if unmatched_original_ids:
            change_summary.append(
                f"  - {len(unmatched_original_ids)} removed component(s): {', '.join(unmatched_original_ids)}"
            )
        if warnings:
            change_summary.append(
                f"  ! {len(warnings)} COMPLETE behavioral spec removal(s)"
            )

        print("Proposed changes:")
        for line in change_summary:
            print(line)
        try:
            answer = input("Proceed with merge? [y/N] ").strip().lower()
        except EOFError:
            answer = "n"
        if answer != "y":
            print("Merge cancelled.", file=sys.stderr)
            _emit_output("error", error_message="Merge cancelled by user")
            return 1, [], [], [], [], []

    return (
        0,
        merged_components,
        warnings,
        matched,
        unmatched_new_ids,
        unmatched_original_ids,
    )


def _write_outputs(
    output_dir: Path,
    original_spatial: dict,
    original_tokens_md: str,
    merged_components: list[dict],
    figma_components: list[dict],
    original_components: list[dict],
    matched: list[tuple[str, str]],
    unmatched_new_ids: list[str],
    unmatched_original_ids: list[str],
    warnings: list[str],
) -> int:
    """Validate post-merge, write artifacts, and emit the output JSON.

    Returns 0 on success, 1 on post-merge validation failure.
    """
    merged_spatial: dict = dict(original_spatial)
    merged_spatial["components"] = merged_components

    merged_svg = generate_svg(merged_spatial)

    # Build figma_data for tokens merge: use component ID as name key so that
    # merge_tokens can match against tokens.md section headers (keyed by ID).
    figma_data_for_tokens: dict = {
        "components": [
            {
                "name": c.get("id", ""),
                "tag": c.get("tag", "EXISTING"),
                "fills": [],
                "size": {},
            }
            for c in merged_components
            if c.get("id", "")
        ]
    }
    merged_tokens_md = merge_tokens(original_tokens_md, figma_data_for_tokens)

    # Post-merge: validate spatial ↔ SVG linkage on merged outputs
    # Only check spatial/SVG consistency (not tokens) since tokens format may vary
    # across projects and may not use component IDs as section headers.
    # Pre-flight above already verified input consistency; post-merge guards the
    # generated SVG against any regeneration bug.
    svg_violations = validate_id_linkage(merged_spatial, merged_svg, "")
    if svg_violations:
        for v in svg_violations:
            if v.get("artifact") != "tokens.md":
                print(
                    f"ERROR: ID-linkage violation — id='{v.get('id')}' "
                    f"artifact='{v.get('artifact')}' type='{v.get('violation_type')}'",
                    file=sys.stderr,
                )
        svg_only = [v for v in svg_violations if v.get("artifact") != "tokens.md"]
        if svg_only:
            _emit_output(
                "error",
                error_message="Post-merge ID-linkage violation — see stderr for details",
            )
            return 1

    original_by_id: dict[str, dict] = {c.get("id", ""): c for c in original_components}
    figma_by_id: dict[str, dict] = {c.get("id", ""): c for c in figma_components}

    components_added = len(unmatched_new_ids)
    components_removed = len(unmatched_original_ids)
    components_modified = _count_visual_modifications(
        matched, original_by_id, figma_by_id
    )
    behavioral_specs_preserved = sum(
        1
        for _figma_id, orig_id in matched
        if original_by_id.get(orig_id, {}).get("behavioral_spec_status") == "COMPLETE"
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    _write_json(output_dir / "spatial-layout.json", merged_spatial)
    _write_text(output_dir / "wireframe.svg", merged_svg)
    _write_text(output_dir / "tokens.md", merged_tokens_md)

    _emit_output(
        "success",
        components_added=components_added,
        components_modified=components_modified,
        components_removed=components_removed,
        behavioral_specs_preserved=behavioral_specs_preserved,
        warnings=warnings,
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    manifest_dir = Path(args.manifest_dir)
    revised_spatial_path = Path(args.revised_spatial)
    output_dir = Path(args.output_dir) if args.output_dir else manifest_dir

    (
        original_spatial,
        original_svg,
        original_tokens_md,
        _figma_revised,
        figma_components,
        original_components,
    ) = _load_inputs(manifest_dir, revised_spatial_path)

    (
        exit_code,
        merged_components,
        warnings,
        matched,
        unmatched_new_ids,
        unmatched_original_ids,
    ) = _run_merge_pipeline(
        original_spatial,
        original_svg,
        original_tokens_md,
        figma_components,
        original_components,
        args.non_interactive,
    )
    if exit_code != 0:
        return exit_code

    return _write_outputs(
        output_dir,
        original_spatial,
        original_tokens_md,
        merged_components,
        figma_components,
        original_components,
        matched,
        unmatched_new_ids,
        unmatched_original_ids,
        warnings,
    )


if __name__ == "__main__":
    sys.exit(main())
