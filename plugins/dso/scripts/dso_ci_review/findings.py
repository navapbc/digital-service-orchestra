"""Reviewer findings extraction and merge utilities.

Ported from the _extract_json_from_llm_text() python3 heredoc in
ci-llm-review-runner.sh.
"""

from __future__ import annotations

import json


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
