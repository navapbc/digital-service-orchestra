"""Tests for the brainstorm SKILL.md gap analysis (Step 2.5) content requirements.

TDD spec for story b81e-2106:
- plugins/dso/skills/brainstorm/SKILL.md Step 2.5 must contain:
  1. Artifact contradiction detection — comparing user-named artifacts against SC text
  2. Qualitative completeness questions that prompt the spec author to verify SCs are exhaustive
  3. Fuzzy matching guidance to avoid false positives (e.g., "tk" matching "bare tk CLI references")
  4. The gap analysis must occur before the fidelity review (Step 3)
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "brainstorm" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


def test_brainstorm_skill_file_exists() -> None:
    """The brainstorm SKILL.md file must exist at the expected path."""
    assert SKILL_FILE.exists(), (
        f"Expected brainstorm skill file to exist at {SKILL_FILE}."
    )


def test_gap_analysis_detects_artifact_omission() -> None:
    """Step 2.5 must instruct the agent to compare user-named artifacts against SCs.

    The gap analysis must cross-reference artifacts the user explicitly named in their
    request against the success criteria text, flagging any that are missing.
    """
    content = _read_skill()
    # Check that the gap analysis section addresses artifact omission detection
    assert "artifact" in content.lower(), (
        "Expected brainstorm SKILL.md Step 2.5 gap analysis to reference 'artifact' "
        "detection — comparing user-named artifacts against success criteria text. "
        "This is a RED test — the contradiction detection logic does not yet exist."
    )
    # More specific check: the skill must instruct comparing user's request to SCs
    assert any(
        phrase in content
        for phrase in [
            "user-named artifact",
            "user named artifact",
            "user explicitly named",
            "named in their request",
            "named in the request",
            "named by the user",
        ]
    ), (
        "Expected brainstorm SKILL.md gap analysis to contain language about "
        "artifacts the user explicitly named in their request. "
        "The gap analysis must detect when SCs omit artifacts the user named. "
        "This is a RED test — the contradiction detection logic does not yet exist."
    )


def test_gap_analysis_surfaces_completeness_questions() -> None:
    """Step 2.5 must surface qualitative completeness questions before fidelity review.

    The gap analysis must ask whether success criteria are exhaustive relative to what
    the user asked for, prompting the spec author to verify completeness.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in [
            "exhaustive",
            "completeness",
            "Are the SCs exhaustive",
            "Are the success criteria exhaustive",
            "complete relative to",
            "everything the user asked for",
        ]
    ), (
        "Expected brainstorm SKILL.md Step 2.5 to surface qualitative completeness "
        "questions — asking whether SCs are exhaustive relative to what the user asked "
        "for. This is a RED test — the completeness question logic does not yet exist."
    )


def test_gap_analysis_includes_fuzzy_matching_guidance() -> None:
    """Step 2.5 must include fuzzy matching guidance to avoid false positives.

    The contradiction detection must handle cases where the user says 'tk' but the SC
    says 'bare tk CLI references' — both should count as covered, not flagged as missing.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in [
            "fuzzy",
            "partial match",
            "abbreviation",
            "alias",
            "variant",
            "synonym",
        ]
    ), (
        "Expected brainstorm SKILL.md Step 2.5 to include fuzzy matching guidance to "
        "avoid false positives (e.g., 'tk' matching 'bare tk CLI references' counts as "
        "covered). This is a RED test — the fuzzy matching guidance does not yet exist."
    )


def test_gap_analysis_precedes_fidelity_review() -> None:
    """Step 2.5 (gap analysis) must appear before Step 3 (fidelity review) in the skill.

    The gap analysis must surface completeness gaps BEFORE the fidelity review runs,
    so the spec author can address them before reviewers evaluate the spec.
    """
    content = _read_skill()
    # Find positions of the gap analysis section and the fidelity review section
    gap_analysis_pos = content.find("Step 2.5")
    fidelity_review_pos = content.find("Step 3")
    assert gap_analysis_pos != -1, (
        "Expected brainstorm SKILL.md to contain a 'Step 2.5' section for gap analysis. "
        "This is a RED test — Step 2.5 gap analysis section may not be labeled correctly."
    )
    assert fidelity_review_pos != -1, (
        "Expected brainstorm SKILL.md to contain a 'Step 3' section for fidelity review."
    )
    assert gap_analysis_pos < fidelity_review_pos, (
        "Expected Step 2.5 (gap analysis) to appear BEFORE Step 3 (fidelity review) "
        "in the brainstorm SKILL.md. Gap analysis must run before reviewers evaluate "
        "the spec so completeness gaps can be addressed first."
    )


def test_gap_analysis_flags_missing_artifacts_before_review() -> None:
    """Step 2.5 must flag missing artifacts and prompt resolution before fidelity review.

    After detecting missing artifacts, the skill must instruct the agent to present
    the gaps to the user (or resolve them in the spec) before proceeding to Step 3.
    """
    content = _read_skill()
    # The gap analysis section should mention flagging or presenting gaps
    assert any(
        phrase in content
        for phrase in [
            "flag",
            "missing from",
            "not covered",
            "omitted",
            "absent from",
        ]
    ), (
        "Expected brainstorm SKILL.md Step 2.5 to instruct flagging artifacts missing "
        "from success criteria. The skill must detect and surface omissions before the "
        "fidelity review. This is a RED test — the flagging logic does not yet exist."
    )
