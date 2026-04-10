"""
figma_merge — public API for Figma design-to-code merge utilities.

Submodules (spatial, tokens, svg, validation) are not yet implemented.
Each exported function raises NotImplementedError until the corresponding
submodule is created and wired in.
"""


def merge_spatial(figma_data, target):
    """Merge spatial layout data from a Figma design into *target*.

    Raises:
        NotImplementedError: Submodule not yet implemented.
    """
    raise NotImplementedError("not yet implemented")


def merge_tokens(figma_data, target):
    """Merge design tokens from a Figma design into *target*.

    Raises:
        NotImplementedError: Submodule not yet implemented.
    """
    raise NotImplementedError("not yet implemented")


def generate_svg(figma_data):
    """Generate an SVG representation from *figma_data*.

    Raises:
        NotImplementedError: Submodule not yet implemented.
    """
    raise NotImplementedError("not yet implemented")


def validate_id_linkage(figma_data, component_map):
    """Validate that all Figma node IDs in *figma_data* are present in *component_map*.

    Raises:
        NotImplementedError: Submodule not yet implemented.
    """
    raise NotImplementedError("not yet implemented")


__all__ = [
    "merge_spatial",
    "merge_tokens",
    "generate_svg",
    "validate_id_linkage",
]
