"""Proximity overlap detection for CI review deduplication.

Functions:
    compute_proximity_overlap: Check if finding and prior cited lines are within ±5 lines.
    validate_escape_rationale: Check if escape text references lines outside prior/overlap region.
"""

from __future__ import annotations

import re


def _parse_cited_line(cited: str) -> tuple[str, int] | None:
    """Parse 'file/path.py:42' into (path, lineno). Returns None on failure."""
    if ":" not in cited:
        return None
    path, _, lineno_str = cited.rpartition(":")
    try:
        return path, int(lineno_str)
    except ValueError:
        return None


def compute_proximity_overlap(finding_lines: list[str], prior_lines: list[str]) -> bool:
    """Return True if any finding line is within ±5 lines of any prior line in the same file.

    Args:
        finding_lines: Cited lines from the new finding, format 'file/path.py:42'.
        prior_lines: Cited lines from the prior finding, format 'file/path.py:40'.

    Returns:
        True if any (finding, prior) pair shares the same file and |lineno_finding - lineno_prior| <= 5.
    """
    parsed_finding = [_parse_cited_line(c) for c in finding_lines]
    parsed_prior = [_parse_cited_line(c) for c in prior_lines]

    for f_entry in parsed_finding:
        if f_entry is None:
            continue
        f_path, f_lineno = f_entry
        for p_entry in parsed_prior:
            if p_entry is None:
                continue
            p_path, p_lineno = p_entry
            if f_path == p_path and abs(f_lineno - p_lineno) <= 5:
                return True
    return False


def validate_escape_rationale(
    escape_text: str,
    prior_cited_lines: list[str],
    overlap_region: list[str],
) -> bool:
    """Return True if escape_text references at least one line outside prior/overlap region.

    A referenced line is "in prior" if it appears in prior_cited_lines (parsed as path:lineno).
    A referenced line is "in overlap region" if it falls within any overlap_region range.
    Returns True only when at least one referenced line is NOT in prior or overlap region.
    Returns False if all referenced lines are in prior/overlap, or if no lines are referenced.

    Args:
        escape_text: Free-text rationale for why this finding differs from a prior finding.
        prior_cited_lines: Cited lines from the prior finding, format 'file/path.py:42'.
        overlap_region: Overlap regions, format 'file/path.py:40-47'.
    """
    # Extract all referenced line numbers from escape_text
    # Match "line N" or ":N" patterns
    referenced_linenos: set[int] = set()
    for m in re.finditer(r"(?:line\s+(\d+)|:(\d+))", escape_text, re.IGNORECASE):
        num_str = m.group(1) or m.group(2)
        referenced_linenos.add(int(num_str))

    if not referenced_linenos:
        return False

    # Build set of prior line numbers
    prior_linenos: set[int] = set()
    for cited in prior_cited_lines:
        parsed = _parse_cited_line(cited)
        if parsed is not None:
            prior_linenos.add(parsed[1])

    # Build set of line numbers covered by overlap regions
    overlap_linenos: set[int] = set()
    for region in overlap_region:
        # Format: 'file/path.py:40-47'
        if ":" not in region:
            continue
        _, _, range_str = region.rpartition(":")
        if "-" in range_str:
            parts = range_str.split("-", 1)
            try:
                start, end = int(parts[0]), int(parts[1])
                overlap_linenos.update(range(start, end + 1))
            except ValueError:
                pass
        else:
            try:
                overlap_linenos.add(int(range_str))
            except ValueError:
                pass

    excluded = prior_linenos | overlap_linenos

    # Return True if at least one referenced line is outside excluded set
    for lineno in referenced_linenos:
        if lineno not in excluded:
            return True
    return False
