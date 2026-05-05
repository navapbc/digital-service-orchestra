"""Diff classifier for CI review tier selection.

Pure function — no filesystem reads, no subprocess calls.
"""

from __future__ import annotations

import re

# ---------------------------------------------------------------------------
# Keyword sets for overlay detection
# ---------------------------------------------------------------------------

_SECURITY_KEYWORDS = frozenset(
    ["password", "secret", "api_key", "token", "credential", "auth"]
)
_PERFORMANCE_KEYWORDS = frozenset(["cache", "database", "query", "index", "optimize"])

# Directories that bump the critical-path score
_CRITICAL_DIRS = frozenset(["db/", "auth/", "routes/", "middleware/"])

# Anti-shortcut markers
_SHORTCUT_MARKERS = ["TODO", "FIXME", "HACK", "workaround"]


def classify_tier(diff_text: str) -> dict:
    """Classify a PR diff and return tier + overlay flags.

    Returns:
        {
          "selected_tier": "light" | "standard" | "deep",
          "size_action": "none" | "warn" | "upgrade",
          "security_overlay": bool,
          "performance_overlay": bool,
          "test_quality_overlay": bool,
          "diff_size_lines": int,
          "blast_radius": int,
          "critical_path": int,
          "anti_shortcut": int,
          "staleness": int,
          "cross_cutting": int,
          "diff_lines": int,
          "change_volume": int,
          "computed_total": int,
          "is_merge_commit": bool,
        }
    """
    if not diff_text or not diff_text.strip():
        return {
            "selected_tier": "light",
            "size_action": "none",
            "security_overlay": False,
            "performance_overlay": False,
            "test_quality_overlay": False,
            "diff_size_lines": 0,
            "blast_radius": 0,
            "critical_path": 0,
            "anti_shortcut": 0,
            "staleness": 0,
            "cross_cutting": 0,
            "diff_lines": 0,
            "change_volume": 0,
            "computed_total": 0,
            "is_merge_commit": False,
        }

    lines = diff_text.splitlines()

    # ------------------------------------------------------------------
    # Collect changed file paths from diff headers
    # ------------------------------------------------------------------
    changed_files: list[str] = []
    for line in lines:
        # Match "diff --git a/path b/path" or "+++ b/path" headers
        m = re.match(r"^diff --git a/(.+?) b/(.+)$", line)
        if m:
            changed_files.append(m.group(2))

    # Deduplicate while preserving order
    seen: set[str] = set()
    unique_files: list[str] = []
    for f in changed_files:
        if f not in seen:
            seen.add(f)
            unique_files.append(f)

    n_files = len(unique_files)

    # ------------------------------------------------------------------
    # diff_size_lines: count +/- lines (not headers)
    # ------------------------------------------------------------------
    diff_size_lines = sum(
        1
        for line in lines
        if line.startswith("+") or line.startswith("-")
        if not line.startswith("+++") and not line.startswith("---")
    )

    # ------------------------------------------------------------------
    # Overlay flags
    # ------------------------------------------------------------------
    diff_lower = diff_text.lower()

    security_overlay = any(kw in diff_lower for kw in _SECURITY_KEYWORDS)
    performance_overlay = any(kw in diff_lower for kw in _PERFORMANCE_KEYWORDS)
    test_quality_overlay = any(
        "tests/" in f or f.startswith("tests/") for f in unique_files
    ) or bool(re.search(r"\btests/", diff_text))

    # ------------------------------------------------------------------
    # is_merge_commit: heuristic — diff mentions "Merge" in first lines
    # ------------------------------------------------------------------
    first_lines = "\n".join(lines[:5])
    is_merge_commit = bool(re.search(r"\bMerge\b", first_lines))

    # ------------------------------------------------------------------
    # Score components
    # ------------------------------------------------------------------

    # blast_radius (0–3): number of changed files, capped at 3
    blast_radius = min(n_files, 3)

    # critical_path (0–3): any file in critical dirs → +1
    critical_path = 0
    for f in unique_files:
        if any(d in f for d in _CRITICAL_DIRS):
            critical_path += 1
            if critical_path >= 3:
                break

    # anti_shortcut (0–3): added lines with markers → +1 each, cap 3
    anti_shortcut = 0
    for line in lines:
        if line.startswith("+") and not line.startswith("+++"):
            for marker in _SHORTCUT_MARKERS:
                if marker in line:
                    anti_shortcut += 1
                    break  # only count once per line
            if anti_shortcut >= 3:
                break

    # staleness (0–2): force push or mass rename → +1
    staleness = 0
    if "force" in diff_lower and "push" in diff_lower:
        staleness += 1
    # mass rename: many "rename" or "{..." patterns in diff headers
    rename_count = len(re.findall(r"\{.*?=>.*?\}", diff_text))
    if rename_count >= 3:
        staleness += 1
    staleness = min(staleness, 2)

    # cross_cutting (0–2): changes span multiple directories → +1
    dirs = set()
    for f in unique_files:
        parts = f.split("/")
        if len(parts) > 1:
            dirs.add(parts[0])
        else:
            dirs.add("")
    cross_cutting = min(1, max(0, len(dirs) - 1)) if len(dirs) > 1 else 0

    # diff_lines (0–1): changed lines > 10 → +1
    diff_lines = 1 if diff_size_lines > 10 else 0

    # change_volume (0–1): changed files > 2 → +1 (minimum 1)
    change_volume = 1 if n_files > 2 else max(1, 0)
    # "minimum 1" is interpreted as the score component itself is at least 1
    # when files > 2; but "minimum 1" likely means min value of changed_files
    # used in computation is 1. Re-read: "changed files >2 → +1 (minimum 1)"
    # means if files >2: +1, otherwise +0, but minimum treated as 1 file.
    # Keep simple: +1 if n_files > 2, else 0.
    change_volume = 1 if n_files > 2 else 0

    computed_total = (
        blast_radius
        + critical_path
        + anti_shortcut
        + staleness
        + cross_cutting
        + diff_lines
        + change_volume
    )

    # ------------------------------------------------------------------
    # Tier selection
    # ------------------------------------------------------------------
    if computed_total >= 7:
        selected_tier = "deep"
    elif computed_total >= 3:
        selected_tier = "standard"
    else:
        selected_tier = "light"

    # ------------------------------------------------------------------
    # Size action
    # ------------------------------------------------------------------
    if diff_size_lines >= 600:
        size_action = "upgrade"
    elif diff_size_lines >= 300:
        size_action = "warn"
    else:
        size_action = "none"

    return {
        "selected_tier": selected_tier,
        "size_action": size_action,
        "security_overlay": security_overlay,
        "performance_overlay": performance_overlay,
        "test_quality_overlay": test_quality_overlay,
        "diff_size_lines": diff_size_lines,
        "blast_radius": blast_radius,
        "critical_path": critical_path,
        "anti_shortcut": anti_shortcut,
        "staleness": staleness,
        "cross_cutting": cross_cutting,
        "diff_lines": diff_lines,
        "change_volume": change_volume,
        "computed_total": computed_total,
        "is_merge_commit": is_merge_commit,
    }
