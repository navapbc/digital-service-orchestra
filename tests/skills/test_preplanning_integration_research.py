"""Tests for content requirements of the integration research step in preplanning SKILL.md.

TDD spec for story 86e9-cefd (RED task ec4f-575c):
- plugins/dso/skills/preplanning/SKILL.md must contain an integration research section:
  1. Section exists (case-insensitive) with 'integration research' heading
  2. Section appears AFTER Phase 2 (Risk & Scope Scan) and BEFORE Phase 2.5 (Adversarial Review)
  3. Section references WebSearch
  4. Section references 'Verified Integration Constraints' as output format
  5. Section references sandbox availability flagging
  6. Section references high-risk flagging for spike creation

These tests FAIL (RED) because the integration research section does not yet exist in preplanning SKILL.md.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "preplanning" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


def test_integration_research_section_exists() -> None:
    """SKILL.md must contain an 'Integration Research' or 'integration research' section."""
    content = _read_skill()
    match = re.search(r"integration research", content, re.IGNORECASE)
    assert match is not None, (
        "Expected plugins/dso/skills/preplanning/SKILL.md to contain an 'Integration Research' "
        "section (case-insensitive). This section does not yet exist — this is a RED test. "
        "The section must be added by story 86e9-cefd as a new phase between Phase 2 and Phase 2.5."
    )


def test_integration_research_section_after_phase_2() -> None:
    """Integration research section must appear AFTER Phase 2 (Risk & Scope Scan)."""
    content = _read_skill()
    phase2_match = re.search(r"Phase 2:.*Risk.*Scope Scan", content, re.IGNORECASE)
    integration_match = re.search(r"integration research", content, re.IGNORECASE)

    assert phase2_match is not None, (
        "Expected SKILL.md to contain a 'Phase 2: Risk & Scope Scan' heading. "
        "Cannot verify integration research placement without locating Phase 2."
    )
    assert integration_match is not None, (
        "Expected SKILL.md to contain an 'integration research' section. "
        "The section does not yet exist — this is a RED test."
    )
    assert integration_match.start() > phase2_match.start(), (
        "Expected 'integration research' section to appear AFTER 'Phase 2: Risk & Scope Scan'. "
        f"Phase 2 found at position {phase2_match.start()}, "
        f"integration research found at position {integration_match.start()}. "
        "The integration research step must follow Phase 2 in the skill workflow."
    )


def test_integration_research_section_before_phase_2_5() -> None:
    """Integration research section must appear BEFORE Phase 2.5 (Adversarial Review)."""
    content = _read_skill()
    phase_2_5_match = re.search(
        r"Phase 2\.5:.*Adversarial Review", content, re.IGNORECASE
    )
    integration_match = re.search(r"integration research", content, re.IGNORECASE)

    assert phase_2_5_match is not None, (
        "Expected SKILL.md to contain a 'Phase 2.5: Adversarial Review' heading. "
        "Cannot verify integration research placement without locating Phase 2.5."
    )
    assert integration_match is not None, (
        "Expected SKILL.md to contain an 'integration research' section. "
        "The section does not yet exist — this is a RED test."
    )
    assert integration_match.start() < phase_2_5_match.start(), (
        "Expected 'integration research' section to appear BEFORE 'Phase 2.5: Adversarial Review'. "
        f"Integration research found at position {integration_match.start()}, "
        f"Phase 2.5 found at position {phase_2_5_match.start()}. "
        "The integration research step must precede the adversarial review phase."
    )


def test_integration_research_references_websearch() -> None:
    """Integration research section must reference WebSearch for finding known-working code."""
    content = _read_skill()
    integration_match = re.search(r"integration research", content, re.IGNORECASE)
    assert integration_match is not None, (
        "Expected SKILL.md to contain an 'integration research' section. "
        "The section does not yet exist — this is a RED test."
    )

    # Find the content of the integration research section (up to the next ##-level heading)
    section_start = integration_match.start()
    next_section = re.search(r"\n## ", content[section_start + 1 :])
    section_end = (
        section_start + 1 + next_section.start() if next_section else len(content)
    )
    section_content = content[section_start:section_end]

    assert "WebSearch" in section_content, (
        "Expected the integration research section to reference 'WebSearch'. "
        "The integration research step must use WebSearch to find known-working code patterns "
        "for external integrations flagged in Phase 2. "
        "This reference does not yet exist — this is a RED test."
    )


def test_integration_research_references_verified_integration_constraints() -> None:
    """Integration research section must reference 'Verified Integration Constraints' as output."""
    content = _read_skill()
    integration_match = re.search(r"integration research", content, re.IGNORECASE)
    assert integration_match is not None, (
        "Expected SKILL.md to contain an 'integration research' section. "
        "The section does not yet exist — this is a RED test."
    )

    # Find the content of the integration research section (up to the next ##-level heading)
    section_start = integration_match.start()
    next_section = re.search(r"\n## ", content[section_start + 1 :])
    section_end = (
        section_start + 1 + next_section.start() if next_section else len(content)
    )
    section_content = content[section_start:section_end]

    assert re.search(
        r"Verified Integration Constraints", section_content, re.IGNORECASE
    ), (
        "Expected the integration research section to reference 'Verified Integration Constraints' "
        "as the output format for integration findings. "
        "This named output format does not yet exist in the section — this is a RED test."
    )


def test_integration_research_references_sandbox_availability_flagging() -> None:
    """Integration research section must reference sandbox availability flagging."""
    content = _read_skill()
    integration_match = re.search(r"integration research", content, re.IGNORECASE)
    assert integration_match is not None, (
        "Expected SKILL.md to contain an 'integration research' section. "
        "The section does not yet exist — this is a RED test."
    )

    # Find the content of the integration research section (up to the next ##-level heading)
    section_start = integration_match.start()
    next_section = re.search(r"\n## ", content[section_start + 1 :])
    section_end = (
        section_start + 1 + next_section.start() if next_section else len(content)
    )
    section_content = content[section_start:section_end]

    assert re.search(r"sandbox", section_content, re.IGNORECASE), (
        "Expected the integration research section to reference sandbox availability flagging. "
        "The section must flag whether a sandbox environment is available for the integration "
        "under research (to guide implementation decisions). "
        "This reference does not yet exist — this is a RED test."
    )


def test_integration_research_references_high_risk_spike_creation() -> None:
    """Integration research section must reference high-risk flagging for spike creation."""
    content = _read_skill()
    integration_match = re.search(r"integration research", content, re.IGNORECASE)
    assert integration_match is not None, (
        "Expected SKILL.md to contain an 'integration research' section. "
        "The section does not yet exist — this is a RED test."
    )

    # Find the content of the integration research section (up to the next ##-level heading)
    section_start = integration_match.start()
    next_section = re.search(r"\n## ", content[section_start + 1 :])
    section_end = (
        section_start + 1 + next_section.start() if next_section else len(content)
    )
    section_content = content[section_start:section_end]

    has_high_risk = re.search(r"high.risk|high risk", section_content, re.IGNORECASE)
    has_spike = re.search(r"spike", section_content, re.IGNORECASE)

    assert has_high_risk is not None and has_spike is not None, (
        "Expected the integration research section to reference both 'high-risk' flagging "
        "and 'spike' creation. When integration research reveals insufficient documentation "
        "or ambiguity, the section should flag the integration as high-risk and recommend "
        "creating a spike story. "
        f"Found high-risk reference: {has_high_risk is not None}, "
        f"found spike reference: {has_spike is not None}. "
        "These references do not yet exist — this is a RED test."
    )
