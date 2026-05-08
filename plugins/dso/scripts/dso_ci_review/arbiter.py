"""dso_ci_review.arbiter — Arbiter dispatch and ruling validation.

Provides two public functions:

  dispatch_arbiter  — Sends a finding + prior defense to the code-reviewer-arbiter
                      agent and returns a dict with a 'ruling' key.

  validate_arbiter_ruling — Validates DOWNGRADE_TO rulings to ensure named_rebuttal
                            cites lines NOT already present in reviewer_severity_evidence.
                            Reclassifies invalid DOWNGRADE_TO to ACCEPT_DEFENSE.
"""

from __future__ import annotations

import re
from typing import Any

from dso_ci_review.dispatch import dispatch_review

# Pattern matching file:line references (e.g. "auth/login.py:42")
_FILE_LINE_RE = re.compile(r"[\w./\-]+\.\w+:\d+")


def dispatch_arbiter(
    finding: dict[str, Any],
    prior_defense: dict[str, Any],
    diff_text: str,
    model: str,
    provider_chain: list[str],
) -> dict[str, Any]:
    """Dispatch the arbiter agent to adjudicate a severity dispute.

    Builds a combined diff context that prepends the prior defense text before
    the actual diff, then calls dispatch_review with agent_id='code-reviewer-arbiter'.

    Args:
        finding: The reviewer finding dict (contains id, relation, cited_lines, etc.).
        prior_defense: The author's prior defense dict (contains defense_text).
        diff_text: The unified diff text under review.
        model: Primary model identifier to use.
        provider_chain: Ordered list of provider names.

    Returns:
        A dict containing a 'ruling' key from the arbiter's response.
    """
    defense_text = prior_defense.get("defense_text", "")
    combined_diff = f"## Prior Defense\n\n{defense_text}\n\n## Diff Under Review\n\n{diff_text}"

    result = dispatch_review(
        diff=combined_diff,
        agent_id="code-reviewer-arbiter",
        primary_model=model,
        provider_chain=provider_chain,
    )
    return result


def validate_arbiter_ruling(ruling: dict[str, Any], finding: dict[str, Any]) -> dict[str, Any]:
    """Validate a DOWNGRADE_TO arbiter ruling.

    A DOWNGRADE_TO ruling is only valid when named_rebuttal references at least
    one file:line reference that does NOT appear in reviewer_severity_evidence.
    If named_rebuttal only cites lines already in reviewer_severity_evidence,
    the ruling is reclassified to ACCEPT_DEFENSE.

    Non-DOWNGRADE_TO rulings are returned unchanged.

    Args:
        ruling: The arbiter ruling dict (contains 'ruling' key and optionally
                'severity_rebuttal' sub-dict).
        finding: The original reviewer finding dict (contains 'cited_lines').

    Returns:
        The ruling dict, possibly with ruling='ACCEPT_DEFENSE' if the
        DOWNGRADE_TO was invalid.
    """
    ruling_value: str = ruling.get("ruling", "")
    if not ruling_value.startswith("DOWNGRADE_TO"):
        return ruling

    severity_rebuttal = ruling.get("severity_rebuttal", {})
    named_rebuttal: str = severity_rebuttal.get("named_rebuttal", "")
    reviewer_severity_evidence: str = severity_rebuttal.get("reviewer_severity_evidence", "")

    # Extract file:line references from named_rebuttal
    rebuttal_refs = _FILE_LINE_RE.findall(named_rebuttal)

    if not rebuttal_refs:
        # No file:line references in named_rebuttal → no new evidence → invalid downgrade
        result = dict(ruling)
        result["ruling"] = "ACCEPT_DEFENSE"
        return result

    # Check whether all rebuttal refs appear in reviewer_severity_evidence
    all_in_evidence = all(ref in reviewer_severity_evidence for ref in rebuttal_refs)

    if all_in_evidence:
        # named_rebuttal only cites lines already in the evidence set → invalid downgrade
        result = dict(ruling)
        result["ruling"] = "ACCEPT_DEFENSE"
        return result

    # At least one rebuttal ref is NOT in evidence → valid DOWNGRADE_TO
    return ruling
