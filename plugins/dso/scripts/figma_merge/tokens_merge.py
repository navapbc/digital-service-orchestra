"""
figma_merge.tokens_merge — Merge Figma-derived design tokens into a tokens.md document.

Public API
----------
merge_tokens(original_tokens_md, figma_derived, designer_added=None, designer_removed=None) -> str

Behavioral sections (preserved verbatim):
  - Interaction Behaviors
  - Responsive Rules
  - Accessibility Specification
  - State Definitions

Visual sections (updated from Figma):
  - Component Inventory  (add NEW, remove absent)
  - Visual Properties    (update fills/strokes/dimensions)
"""

from __future__ import annotations

import re
from typing import Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BEHAVIORAL_SECTION_NAMES = frozenset(
    [
        "Interaction Behaviors",
        "Responsive Rules",
        "Accessibility Specification",
        "State Definitions",
    ]
)

INCOMPLETE_MARKER = "INCOMPLETE"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def merge_tokens(
    original_tokens_md: str,
    figma_derived: dict,
    designer_added: Optional[list] = None,
    designer_removed: Optional[list] = None,
) -> str:
    """Merge Figma-derived design tokens into *original_tokens_md*.

    Parameters
    ----------
    original_tokens_md:
        The existing tokens.md content as a string.
    figma_derived:
        Dict with a ``components`` list.  Each component entry has:
        ``name`` (str), ``tag`` (str: "EXISTING" or "NEW"),
        ``fills`` (list[str]), ``size`` (dict with optional "height"/"width").
    designer_added:
        Optional explicit list of component names newly added by designer.
        If omitted, NEW-tagged components in *figma_derived* are treated as
        designer-added.
    designer_removed:
        Optional explicit list of component names removed by designer.
        If omitted, components present in the original but absent from
        *figma_derived* are treated as removed.

    Returns
    -------
    str
        Updated tokens.md content.
    """
    components: list[dict] = figma_derived.get("components", [])

    # Build lookup maps from figma_derived
    figma_by_name: dict[str, dict] = {
        c.get("name", ""): c for c in components if c.get("name", "")
    }
    figma_names: set[str] = set(figma_by_name.keys())

    # Determine NEW and removed sets
    new_components: list[str] = (
        designer_added
        if designer_added is not None
        else [
            c.get("name", "")
            for c in components
            if c.get("tag") == "NEW" and c.get("name", "")
        ]
    )

    # Parse the original markdown into sections
    sections = _parse_sections(original_tokens_md)

    # Collect all component names that existed in the original (from visual sections)
    original_component_names = _extract_component_names(sections)

    removed_components: set[str] = (
        set(designer_removed)
        if designer_removed is not None
        else original_component_names - figma_names
    )

    # Process each section
    output_parts: list[str] = []
    for section in sections:
        header = section["header"]
        section_name = _section_name(header)

        if section_name in BEHAVIORAL_SECTION_NAMES:
            # Preserve verbatim — but strip lines mentioning removed components
            # when the removal was explicitly requested (designer_removed provided).
            # When removal is inferred from figma_derived absence, behavioral sections
            # are left intact (only visual sections are updated).
            if designer_removed is not None and removed_components:
                output_parts.append(
                    _strip_removed_from_behavioral_section(
                        section["raw"], removed_components
                    )
                )
            else:
                output_parts.append(section["raw"])
        elif section_name == "Component Inventory":
            output_parts.append(
                _rebuild_component_inventory(
                    section,
                    figma_by_name=figma_by_name,
                    new_components=new_components,
                    removed_components=removed_components,
                )
            )
        elif section_name == "Visual Properties":
            output_parts.append(
                _rebuild_visual_properties(
                    section,
                    figma_by_name=figma_by_name,
                    new_components=new_components,
                    removed_components=removed_components,
                )
            )
        else:
            # Unknown section — pass through as-is
            output_parts.append(section["raw"])

    result = "".join(output_parts)

    # Remove INCOMPLETE markers for EXISTING components (TM-6 variant)
    result = _strip_incomplete_for_existing(result, figma_by_name)

    return result


# ---------------------------------------------------------------------------
# Section parsing
# ---------------------------------------------------------------------------


def _parse_sections(text: str) -> list[dict]:
    """Split *text* into a list of section dicts.

    Each dict has:
      - ``header``: the heading line (e.g. "## Component Inventory\n")
      - ``body``: text after the heading until the next same-or-higher heading
      - ``raw``: header + body combined
    """
    # Match any heading at level 1 or 2 (## or #)
    heading_pattern = re.compile(r"^(#{1,2})\s+(.+)$", re.MULTILINE)

    matches = list(heading_pattern.finditer(text))
    if not matches:
        return [{"header": "", "body": text, "raw": text, "level": 0}]

    sections: list[dict] = []

    # Text before first heading (preamble)
    if matches[0].start() > 0:
        preamble = text[: matches[0].start()]
        sections.append({"header": "", "body": preamble, "raw": preamble, "level": 0})

    for i, match in enumerate(matches):
        level = len(match.group(1))
        header_line = text[match.start() : match.end()] + "\n"
        body_start = match.end() + 1  # skip the newline after the heading

        if i + 1 < len(matches):
            body_end = matches[i + 1].start()
        else:
            body_end = len(text)

        body = text[body_start:body_end]
        raw = text[match.start() : body_end]

        sections.append(
            {
                "header": header_line,
                "body": body,
                "raw": raw,
                "level": level,
                "name": match.group(2).strip(),
            }
        )

    return sections


def _section_name(header_line: str) -> str:
    """Extract the plain name from a heading line like '## Component Inventory\\n'."""
    m = re.match(r"^#{1,6}\s+(.+?)[\s#]*$", header_line.strip())
    if m:
        return m.group(1).strip()
    return ""


# ---------------------------------------------------------------------------
# Component name discovery
# ---------------------------------------------------------------------------


def _extract_component_names(sections: list[dict]) -> set[str]:
    """Return the set of component names found in Component Inventory or Visual Properties."""
    names: set[str] = set()
    for section in sections:
        if not section.get("name"):
            continue
        sname = section["name"]
        if sname == "Component Inventory":
            # Extract from table rows: | ComponentName | TAG |
            for m in re.finditer(
                r"^\|\s*([^|]+?)\s*\|\s*\w+\s*\|", section["body"], re.MULTILINE
            ):
                candidate = m.group(1).strip()
                if (
                    candidate
                    and not candidate.startswith("-")
                    and candidate.lower() != "component"
                ):
                    names.add(candidate)
        elif sname == "Visual Properties":
            # Extract from ### SubHeadings
            for m in re.finditer(r"^###\s+(.+)$", section["body"], re.MULTILINE):
                names.add(m.group(1).strip())
    return names


# ---------------------------------------------------------------------------
# Section rebuilders
# ---------------------------------------------------------------------------


def _rebuild_component_inventory(
    section: dict,
    *,
    figma_by_name: dict[str, dict],
    new_components: list[str],
    removed_components: set[str],
) -> str:
    """Rebuild the Component Inventory section.

    - Remove entries for removed_components
    - Keep entries for retained EXISTING components
    - Add NEW components at the end of the table
    """
    header = section["header"]
    body = section["body"]
    lines = body.splitlines(keepends=True)

    output_lines: list[str] = []
    for line in lines:
        # Check if this is a table row (not header/separator)
        table_match = re.match(r"^\|\s*([^|]+?)\s*\|\s*(\w+)\s*\|", line)
        if table_match:
            comp_name = table_match.group(1).strip()
            # Skip header row and separator row
            if comp_name.lower() == "component" or set(comp_name) <= set("- "):
                output_lines.append(line)
                continue
            # Skip removed components
            if comp_name in removed_components:
                continue
            output_lines.append(line)
        else:
            output_lines.append(line)

    # Append NEW components to the table
    for comp_name in new_components:
        if comp_name not in removed_components:
            output_lines.append(f"| {comp_name} | NEW |\n")

    return header + "".join(output_lines)


def _rebuild_visual_properties(
    section: dict,
    *,
    figma_by_name: dict[str, dict],
    new_components: list[str],
    removed_components: set[str],
) -> str:
    """Rebuild the Visual Properties section.

    - Remove subsections for removed_components
    - Update fills/size for retained components using figma_by_name
    - Add placeholder subsections for new_components
    """
    header = section["header"]
    body = section["body"]

    # Split body into subsections (### ComponentName blocks)
    subsection_pattern = re.compile(r"^(###\s+.+)$", re.MULTILINE)
    sub_matches = list(subsection_pattern.finditer(body))

    if not sub_matches:
        # No subsections — return as-is with header
        return header + body

    output_parts: list[str] = []

    # Text before first subsection
    if sub_matches[0].start() > 0:
        output_parts.append(body[: sub_matches[0].start()])

    for i, sub_match in enumerate(sub_matches):
        comp_name = sub_match.group(1).strip().lstrip("#").strip()
        sub_start = sub_match.start()
        sub_end = sub_matches[i + 1].start() if i + 1 < len(sub_matches) else len(body)
        sub_body = body[sub_start:sub_end]

        # Skip removed components
        if comp_name in removed_components:
            continue

        # Update with Figma data if available
        if comp_name in figma_by_name:
            sub_body = _update_component_visual_properties(
                comp_name, sub_body, figma_by_name[comp_name]
            )

        output_parts.append(sub_body)

    # Append placeholder subsections for NEW components
    for comp_name in new_components:
        if comp_name not in removed_components:
            figma_comp = figma_by_name.get(comp_name, {})
            fills = figma_comp.get("fills", [])
            size = figma_comp.get("size", {})
            fill_str = fills[0] if fills else "TBD"
            height_str = size.get("height", "TBD")
            width_str = size.get("width", "TBD")
            placeholder = (
                f"\n### {comp_name}\n\n"
                f"- fill: {fill_str}\n"
                f"- size: {height_str} height, {width_str} width\n"
                f"- stroke: INCOMPLETE\n"
            )
            output_parts.append(placeholder)

    return header + "".join(output_parts)


def _update_component_visual_properties(
    comp_name: str, sub_body: str, figma_comp: dict
) -> str:
    """Update fill/size lines in a component's visual properties subsection."""
    fills = figma_comp.get("fills", [])
    size = figma_comp.get("size", {})

    lines = sub_body.splitlines(keepends=True)
    output_lines: list[str] = []

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("- fill:") and fills:
            fill_val = fills[0]
            output_lines.append(f"- fill: {fill_val}\n")
        elif stripped.startswith("- size:") and size:
            height = size.get("height")
            width = size.get("width")
            if height and width:
                output_lines.append(f"- size: {height} height, {width} width\n")
            elif height:
                output_lines.append(f"- size: {height} height\n")
            elif width:
                output_lines.append(f"- size: {width} width\n")
            else:
                output_lines.append(line)
        else:
            output_lines.append(line)

    return "".join(output_lines)


# ---------------------------------------------------------------------------
# Behavioral section cleanup (remove references to removed components)
# ---------------------------------------------------------------------------


def _strip_removed_from_behavioral_section(
    section_raw: str, removed_components: set[str]
) -> str:
    """Remove lines that reference any removed component from a behavioral section.

    Behavioral sections are preserved verbatim EXCEPT that lines containing
    references to designer-removed components are dropped.
    """
    if not removed_components:
        return section_raw

    lines = section_raw.splitlines(keepends=True)
    output: list[str] = []
    for line in lines:
        # Check if this line starts with "- <ComponentName>:" pattern
        # or contains a removed component name as the primary subject
        skip = False
        for comp in removed_components:
            # Match bullet lines like "- CardContainer: ..."
            if re.match(rf"^-\s+{re.escape(comp)}\b", line.strip()):
                skip = True
                break
        if not skip:
            output.append(line)
    return "".join(output)


# ---------------------------------------------------------------------------
# INCOMPLETE marker cleanup
# ---------------------------------------------------------------------------


def _strip_incomplete_for_existing(text: str, figma_by_name: dict[str, dict]) -> str:
    """Remove INCOMPLETE markers that belong to EXISTING components.

    For each EXISTING component, remove any lines that contain only
    '- behavioral_spec_status: INCOMPLETE' or similar INCOMPLETE entries
    within their subsection.
    """
    existing_components = {
        name
        for name, comp in figma_by_name.items()
        if comp.get("tag", "EXISTING") == "EXISTING"
    }

    if not existing_components:
        return text

    # Build pattern to match subsections for existing components
    # and strip INCOMPLETE lines within them
    lines = text.splitlines(keepends=True)
    output_lines: list[str] = []
    current_existing_comp: Optional[str] = None

    for line in lines:
        # Check if we're entering a subsection (### ComponentName)
        sub_match = re.match(r"^###\s+(.+)$", line.rstrip())
        if sub_match:
            comp_name = sub_match.group(1).strip()
            current_existing_comp = (
                comp_name if comp_name in existing_components else None
            )
            output_lines.append(line)
            continue

        # Check if we're entering a new ## section (resets subsection tracking)
        if re.match(r"^##\s+", line):
            current_existing_comp = None
            output_lines.append(line)
            continue

        # If inside an EXISTING component subsection, strip INCOMPLETE lines
        if current_existing_comp is not None:
            if INCOMPLETE_MARKER in line:
                continue  # Skip this line

        output_lines.append(line)

    return "".join(output_lines)
