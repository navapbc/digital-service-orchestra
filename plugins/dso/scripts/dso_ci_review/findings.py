"""Reviewer findings extraction and merge utilities.

Ported from the _extract_json_from_llm_text() python3 heredoc in
ci-llm-review-runner.sh.
"""

from __future__ import annotations

import hashlib
import json

_SEVERITY_RANK: dict[str, int] = {
    "critical": 4,
    "important": 3,
    "fragile": 2,
    "minor": 1,
    "suggestion": 0,
}


def _extract_json_from_text(text: str) -> dict | None:
    """Extract the best JSON dict candidate from arbitrary LLM response text.

    Scanning strategy (ported from ci-llm-review-runner.sh):
    - Strip leading backticks / markdown fence prefix
    - Scan for '{' positions, decode greedily
    - Score candidates: 3 = has 'findings', 2 = has 'summary', 1 = any dict
    - Return the highest-scored candidate (short-circuit on score 3)
    - Return None if no dict found
    """
    if not text or not text.strip():
        return None

    t = text.strip()

    # Strip markdown fence: ``` or ```json
    t2 = t.lstrip("`")
    if t2.startswith("json"):
        t2 = t2[4:]
    t2 = t2.strip()

    dec = json.JSONDecoder()
    pos = 0
    best: dict | None = None
    best_score = 0

    while pos < len(t2):
        i = t2.find("{", pos)
        if i < 0:
            break
        try:
            obj, end = dec.raw_decode(t2, i)
            if isinstance(obj, dict):
                score = 1
                if "summary" in obj:
                    score = 2
                if "findings" in obj:
                    score = 3
                if score > best_score:
                    best = obj
                    best_score = score
                if best_score == 3:
                    break  # perfect match — no need to scan further
            # Advance past the parsed object to avoid re-scanning consumed text
            pos = end
        except json.JSONDecodeError:
            pos = i + 1

    return best


def normalize_findings(response_text: str) -> dict:
    """Extract and normalize reviewer findings from LLM response text.

    Handles:
    - Raw JSON string: {"findings": [...], "scores": {...}, "summary": "..."}
    - Markdown-fenced: ```json\\n{...}\\n```
    - Prose with embedded JSON: extract the best JSON dict found

    Returns reviewer-findings.json schema dict.
    On parse failure: returns {"findings": [{"type": "parse_error", "severity": "important",
        "description": "<msg>", "cited_lines": []}], "scores": {}, "summary": "parse error"}
    """
    candidate = _extract_json_from_text(response_text)

    if candidate is None:
        return {
            "findings": [
                {
                    "type": "parse_error",
                    "severity": "important",
                    "description": f"Could not extract JSON from response: {response_text!r:.200}",
                    "cited_lines": [],
                }
            ],
            "scores": {},
            "summary": "parse error",
        }

    # Ensure required keys are present
    result: dict = dict(candidate)
    if "findings" not in result:
        result["findings"] = []
    if "scores" not in result:
        result["scores"] = {}
    if "summary" not in result:
        result["summary"] = ""

    return result


def merge_findings(*finding_dicts: dict) -> dict:
    """Merge multiple reviewer-findings dicts.

    - Combines "findings" arrays additively
    - Takes min per score dimension (conservative)
    - Returns merged dict with "findings", "scores", "summary" keys
    """
    merged_findings: list = []
    merged_scores: dict[str, int | float] = {}
    summaries: list[str] = []

    for fd in finding_dicts:
        # Combine findings arrays
        findings = fd.get("findings") or []
        merged_findings.extend(findings)

        # Conservative (min) merge of scores
        scores = fd.get("scores") or {}
        for dimension, value in scores.items():
            if not isinstance(value, (int, float)):
                continue
            if dimension not in merged_scores:
                merged_scores[dimension] = value
            else:
                merged_scores[dimension] = min(merged_scores[dimension], value)

        summary = fd.get("summary", "")
        if summary:
            summaries.append(summary)

    return {
        "findings": merged_findings,
        "scores": merged_scores,
        "summary": "; ".join(summaries) if summaries else "",
    }


def _parse_line_range(cited: str) -> tuple[int, int] | None:
    """Parse line range from a cited_lines entry like 'path/file.py:10-25' or 'path/file.py:42'.

    Splits on the last colon to separate file path from line spec.
    Returns (start, end) inclusive, or None if unparseable.
    """
    if not cited or ":" not in cited:
        return None
    _, _, line_spec = cited.rpartition(":")
    line_spec = line_spec.strip()
    if "-" in line_spec:
        parts = line_spec.split("-", 1)
        try:
            start = int(parts[0])
            end = int(parts[1])
            return (start, end)
        except ValueError:
            return None
    else:
        try:
            n = int(line_spec)
            return (n, n)
        except ValueError:
            return None


def _ranges_overlap(a: tuple[int, int], b: tuple[int, int]) -> bool:
    """Return True when [a[0],a[1]] and [b[0],b[1]] intersect (inclusive)."""
    return a[0] <= b[1] and b[0] <= a[1]


def _fingerprint(description: str) -> str:
    """SHA-256 of lowercase whitespace-normalized description."""
    normalized = " ".join(description.lower().split())
    return hashlib.sha256(normalized.encode()).hexdigest()


def _merge_two(primary: dict, secondary: dict) -> dict:
    """Merge secondary finding into primary; returns the merged finding dict."""
    rank_primary = _SEVERITY_RANK.get(primary["severity"], 0)
    rank_secondary = _SEVERITY_RANK.get(secondary["severity"], 0)

    if rank_secondary > rank_primary:
        # secondary wins — swap roles so merged has higher severity
        winner, loser = secondary, primary
    else:
        winner, loser = primary, secondary

    merged = dict(winner)

    rank_winner = _SEVERITY_RANK.get(winner["severity"], 0)
    rank_loser = _SEVERITY_RANK.get(loser["severity"], 0)

    if rank_winner != rank_loser:
        merged["merged_rationale"] = {
            "primary": winner.get("rationale", ""),
            "secondary": loser.get("rationale", ""),
        }
    # equal severity: no merged_rationale added

    return merged


def deduplicate_region_findings(findings: list[dict]) -> list[dict]:
    """Deduplicate findings from parallel region reviewers.

    Dedup key: (file_path, dimension, claim-fingerprint) with line-range overlap
    as secondary grouping for (file_path, dimension) buckets.

    Rules:
    - claim-fingerprint = SHA-256 of lowercase whitespace-normalized description
    - Two findings overlap when their cited line ranges intersect
    - MAX severity wins; if severities differ, merged_rationale={"primary": <higher>, "secondary": <lower>}
    - merged_rationale absent when severities are equal
    - Fingerprint match always deduplicates regardless of line proximity
    """
    # Group by (file_path, dimension)
    groups: dict[tuple[str, str], list[dict]] = {}
    for f in findings:
        key = (f.get("file_path", ""), f.get("dimension", ""))
        groups.setdefault(key, []).append(f)

    result: list[dict] = []

    for group_findings in groups.values():
        # Within each (file_path, dimension) group, merge by fingerprint first,
        # then by line-range overlap. Use a list of "buckets" (already-merged findings).
        buckets: list[dict] = []

        for finding in group_findings:
            fp = _fingerprint(finding.get("description", ""))
            finding_ranges = [
                _parse_line_range(c) for c in finding.get("cited_lines", [])
            ]
            finding_ranges_clean = [r for r in finding_ranges if r is not None]

            merged_into: int | None = None

            # Check fingerprint match first
            for i, bucket in enumerate(buckets):
                bucket_fp = _fingerprint(bucket.get("description", ""))
                if bucket_fp == fp:
                    merged_into = i
                    break

            # Then check line-range overlap (only if no fingerprint match yet)
            if merged_into is None:
                for i, bucket in enumerate(buckets):
                    bucket_ranges = [
                        _parse_line_range(c) for c in bucket.get("cited_lines", [])
                    ]
                    bucket_ranges_clean = [r for r in bucket_ranges if r is not None]
                    overlap_found = any(
                        _ranges_overlap(fr, br)
                        for fr in finding_ranges_clean
                        for br in bucket_ranges_clean
                    )
                    if overlap_found:
                        merged_into = i
                        break

            if merged_into is not None:
                buckets[merged_into] = _merge_two(buckets[merged_into], finding)
            else:
                buckets.append(dict(finding))

        result.extend(buckets)

    return result
