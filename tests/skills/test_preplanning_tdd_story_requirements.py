"""Tests for TDD story requirement language in preplanning/SKILL.md.

TDD spec for task w21-u4q4 (GREEN task):
- SKILL.md must contain explicit TDD story requirement guidance covering:
  1. Unit test DoD requirement — stories that produce code must include a
     'unit test' story or task as a done-of-done requirement
  2. Docs and research story exemption — stories that produce only docs or
     research are exempt from TDD story requirements
  3. E2E test story guidance — language directing when to create an e2e test
     story alongside implementation stories
  4. Integration test story guidance — language directing when integration test
     stories are required
  5. Test story dependency ordering — test stories must depend on (block) the
     implementation stories they cover
  6. RED acceptance criteria — test stories must include acceptance criteria
     confirming the test was observed to fail before implementation
  7. Internal epic exemption — epics that are internal tooling (skills, hooks,
     scripts) may follow a lighter-weight TDD story structure

NOTE: These TDD requirements apply going forward only — no retroactive
cleanup of existing stories or tickets is required.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "preplanning" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def test_skill_md_contains_unit_test_dod_requirement() -> None:
    """SKILL.md must require a unit test story as a done-of-done for code-producing stories."""
    content = _read_skill()
    assert "unit test story" in content.lower() or "unit test dod" in content.lower(), (
        "Expected SKILL.md to contain unit test DoD requirement language — "
        "stories that produce code must include a unit test story or task "
        "as a done-of-done requirement."
    )


def test_skill_md_exempts_docs_and_research_stories() -> None:
    """SKILL.md must explicitly exempt docs-only and research stories from TDD story requirements."""
    content = _read_skill()
    assert (
        "tdd story" in content.lower()
        and ("docs" in content.lower() or "documentation" in content.lower())
        and "research" in content.lower()
        and ("exempt" in content.lower() or "exemption" in content.lower())
    ), (
        "Expected SKILL.md to explicitly exempt docs-only and research stories "
        "from TDD story requirements (must contain 'tdd story' alongside exemption language)."
    )


def test_skill_md_contains_e2e_test_story_guidance() -> None:
    """SKILL.md must include guidance on when to create an e2e test story."""
    content = _read_skill()
    assert (
        "e2e test story" in content.lower()
        or "end-to-end test story" in content.lower()
    ), (
        "Expected SKILL.md to contain e2e test story guidance specifying when "
        "an end-to-end test story should be created alongside implementation stories. "
        "Must contain the specific phrase 'e2e test story' or 'end-to-end test story'."
    )


def test_skill_md_contains_integration_test_story_guidance() -> None:
    """SKILL.md must include guidance on when integration test stories are required."""
    content = _read_skill()
    assert "integration test story" in content.lower(), (
        "Expected SKILL.md to contain integration test story guidance specifying "
        "when integration test stories are required in the epic story map. "
        "Must contain the specific phrase 'integration test story'."
    )


def test_skill_md_contains_test_story_dependency_ordering() -> None:
    """SKILL.md must specify that test stories depend on the implementation stories they cover."""
    content = _read_skill()
    assert (
        "test story" in content.lower()
        and "depend" in content.lower()
        and (
            "implementation story" in content.lower()
            or "implementation stories" in content.lower()
        )
    ), (
        "Expected SKILL.md to specify test story dependency ordering — "
        "test stories must depend on the implementation stories they cover. "
        "Must reference 'test story' together with 'depend' and 'implementation story/stories'."
    )


def test_skill_md_contains_red_acceptance_criteria() -> None:
    """SKILL.md must require RED acceptance criteria confirming tests fail before implementation."""
    content = _read_skill()
    assert (
        "red acceptance criteria" in content.lower()
        or ("observed to fail" in content.lower() and "test story" in content.lower())
        or "confirmed red" in content.lower()
    ), (
        "Expected SKILL.md to require RED acceptance criteria — test stories must "
        "include an AC confirming the test was observed to fail (RED) before "
        "implementation begins. Must contain 'red acceptance criteria', 'confirmed red', "
        "or 'observed to fail' alongside 'test story'."
    )


def test_skill_md_contains_internal_epic_exemption() -> None:
    """SKILL.md must describe an exemption for internal tooling epics."""
    content = _read_skill()
    assert (
        "internal epic exemption" in content.lower()
        or ("internal tooling epic" in content.lower())
        or (
            "internal epic" in content.lower()
            and "tdd story" in content.lower()
            and ("exempt" in content.lower() or "lighter" in content.lower())
        )
    ), (
        "Expected SKILL.md to describe an internal epic exemption allowing "
        "internal tooling epics (skills, hooks, scripts) to follow a "
        "lighter-weight TDD story structure. Must contain 'internal epic exemption', "
        "'internal tooling epic', or 'internal epic' combined with 'tdd story' and exemption language."
    )
