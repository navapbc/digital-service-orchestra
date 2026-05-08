"""RED tests for dso_ci_review.arbiter module (not yet created).

Testing mode: RED — arbiter module does not exist yet.
All tests MUST fail with ImportError before implementation.

Behavioral contracts under test:
1. dispatch_arbiter calls dispatch_review with agent_id='code-reviewer-arbiter'
   and includes prior defense text in the diff payload.
2. validate_arbiter_ruling rejects DOWNGRADE_TO when named_rebuttal only
   references lines already cited as evidence (reclassifies to ACCEPT_DEFENSE).
3. validate_arbiter_ruling accepts DOWNGRADE_TO when named_rebuttal references
   a line NOT in the reviewer's evidence set.
"""

from __future__ import annotations

import sys
import pathlib
from unittest.mock import MagicMock, patch

import pytest

# Ensure the plugin scripts directory is on sys.path so that
# `dso_ci_review.arbiter` resolves to the plugin source, not the test package.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.arbiter import dispatch_arbiter, validate_arbiter_ruling  # noqa: E402


# ---------------------------------------------------------------------------
# Test 1: dispatch_arbiter calls dispatch_review with arbiter agent + defense context
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_called_on_resustain_of_with_prior_defense():
    """Given: a finding with relation=RESUSTAIN_OF AND prior_defense exists
    When: dispatch_arbiter(finding, prior_defense, diff_text, model, provider_chain) called
    Then:
    - dispatch_review was called with agent_id='code-reviewer-arbiter'
    - The diff passed to dispatch_review contains the defense text
    - Returns a dict with a 'ruling' key
    """
    finding = {
        "id": "f1",
        "relation": "RESUSTAIN_OF",
        "prior_finding_id": "f0",
        "cited_lines": ["auth/login.py:42"],
        "dimension": "correctness",
        "severity": "critical",
    }
    prior_defense = {
        "finding_id": "f0",
        "defense_text": "We added null-check at line 42 in commit abc123.",
    }
    diff_text = "--- a/auth/login.py\n+++ b/auth/login.py\n@@ -40,3 +40,4 @@ def login():\n+    if user is None:\n+        raise ValueError\n"
    model = "claude-sonnet-4-6"
    provider_chain = ["anthropic"]

    fake_ruling = {"ruling": "SUSTAIN", "rationale": "defense insufficient"}

    with patch(
        "dso_ci_review.arbiter.dispatch_review", return_value=fake_ruling
    ) as mock_dispatch:
        result = dispatch_arbiter(
            finding, prior_defense, diff_text, model, provider_chain
        )

    # agent_id must be the arbiter agent
    call_kwargs = mock_dispatch.call_args
    assert call_kwargs is not None, "dispatch_review was never called"

    # Extract agent_id from positional or keyword args
    args, kwargs = call_kwargs
    agent_id_used = kwargs.get("agent_id") or (args[0] if args else None)
    assert agent_id_used == "code-reviewer-arbiter", (
        f"Expected agent_id='code-reviewer-arbiter', got {agent_id_used!r}"
    )

    # The diff payload forwarded to dispatch_review must contain the defense text
    diff_arg = kwargs.get("diff") or kwargs.get("diff_text") or (args[1] if len(args) > 1 else None)
    assert diff_arg is not None, "No diff argument passed to dispatch_review"
    assert prior_defense["defense_text"] in diff_arg, (
        "Prior defense text not embedded in diff sent to arbiter"
    )

    # Return value must have a 'ruling' key
    assert "ruling" in result, f"Expected 'ruling' key in result, got: {list(result.keys())!r}"


# ---------------------------------------------------------------------------
# Test 2: DOWNGRADE_TO rejected when named_rebuttal only cites evidence lines
# ---------------------------------------------------------------------------


def test_downgrade_to_rejected_when_named_rebuttal_only_references_prior_lines():
    """Given: arbiter ruling = DOWNGRADE_TO_important, but named_rebuttal only
              references a line already in reviewer_severity_evidence
       finding cited_lines = ['auth/login.py:42']
    When: validate_arbiter_ruling(ruling, finding) called
    Then: returns a ruling with ruling='ACCEPT_DEFENSE' (DOWNGRADE_TO rejected)
    """
    ruling = {
        "ruling": "DOWNGRADE_TO_important",
        "severity_rebuttal": {
            "reviewer_claimed_severity": "critical",
            "reviewer_severity_evidence": "auth/login.py:42",
            "named_rebuttal": "line 42 is actually handled",
        },
    }
    finding = {
        "id": "f1",
        "cited_lines": ["auth/login.py:42"],
        "severity": "critical",
    }

    result = validate_arbiter_ruling(ruling, finding)

    assert result["ruling"] == "ACCEPT_DEFENSE", (
        f"Expected ruling='ACCEPT_DEFENSE' when named_rebuttal only references "
        f"evidence lines, got: {result['ruling']!r}"
    )


# ---------------------------------------------------------------------------
# Test 3: DOWNGRADE_TO accepted when named_rebuttal references a non-evidence line
# ---------------------------------------------------------------------------


def test_downgrade_to_accepted_when_named_rebuttal_references_non_evidence_line():
    """Given: arbiter ruling = DOWNGRADE_TO_style, named_rebuttal references
              auth/login.py:55 which is NOT in reviewer_severity_evidence
       finding cited_lines = ['auth/login.py:42']
    When: validate_arbiter_ruling called
    Then: returns ruling unchanged (DOWNGRADE_TO_style is valid)
    """
    ruling = {
        "ruling": "DOWNGRADE_TO_style",
        "severity_rebuttal": {
            "reviewer_claimed_severity": "critical",
            "reviewer_severity_evidence": "auth/login.py:42",
            "named_rebuttal": "auth/login.py:55 shows the mitigation exists",
        },
    }
    finding = {
        "id": "f1",
        "cited_lines": ["auth/login.py:42"],
        "severity": "critical",
    }

    result = validate_arbiter_ruling(ruling, finding)

    assert result["ruling"] == "DOWNGRADE_TO_style", (
        f"Expected ruling='DOWNGRADE_TO_style' to be preserved when named_rebuttal "
        f"references a non-evidence line, got: {result['ruling']!r}"
    )
