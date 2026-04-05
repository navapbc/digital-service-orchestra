"""Tests asserting feature-intent detection guidance in using-lockpick skill files.

TDD RED phase: These tests assert that SKILL.md and HOOK-INJECTION.md contain a
Feature Intent Detection section with concrete signal patterns. They FAIL against
the current unmodified files because this section does not yet exist.

When GREEN: The implementation task will add a Feature Intent Detection section to
SKILL.md and matching guidance to HOOK-INJECTION.md.
"""

import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

SKILL_MD_PATH = os.path.join(
    REPO_ROOT,
    "plugins",
    "dso",
    "skills",
    "using-lockpick",
    "SKILL.md",
)

HOOK_INJECTION_MD_PATH = os.path.join(
    REPO_ROOT,
    "plugins",
    "dso",
    "skills",
    "using-lockpick",
    "HOOK-INJECTION.md",
)


def _read_skill_md() -> str:
    with open(SKILL_MD_PATH) as f:
        return f.read()


def _read_hook_injection_md() -> str:
    with open(HOOK_INJECTION_MD_PATH) as f:
        return f.read()


class TestSkillMdFeatureIntentDetectionSection:
    """SKILL.md must contain a Feature Intent Detection section.

    This section teaches agents to recognize when a user's message signals
    intent to build a new feature, so they can route to /dso:brainstorm
    rather than jumping directly to implementation skills.
    """

    def test_feature_intent_detection_section_exists(self) -> None:
        """SKILL.md must contain a Feature Intent Detection section heading."""
        content = _read_skill_md()
        assert (
            "Feature Intent Detection" in content or "feature intent" in content.lower()
        ), (
            "Expected SKILL.md to contain a 'Feature Intent Detection' section. "
            "This section is needed so agents recognize feature-request signals and "
            "route to /dso:brainstorm before jumping to implementation."
        )

    def test_feature_intent_signal_new_feature(self) -> None:
        """SKILL.md must include 'new feature' as an explicit feature-intent signal pattern."""
        content = _read_skill_md()
        assert "new feature" in content, (
            "Expected SKILL.md to list 'new feature' as a feature-intent signal pattern "
            "in the Feature Intent Detection section. Agents must recognize this phrase "
            "as indicating the user wants to build something new."
        )

    def test_feature_intent_signal_create_an_epic(self) -> None:
        """SKILL.md must include 'create an epic' as an explicit feature-intent signal pattern."""
        content = _read_skill_md()
        assert "create an epic" in content, (
            "Expected SKILL.md to list 'create an epic' as a feature-intent signal pattern "
            "in the Feature Intent Detection section. Agents must recognize this phrase as "
            "an explicit request to start the feature lifecycle."
        )

    def test_feature_intent_signal_i_want_to_build(self) -> None:
        """SKILL.md must include 'I want to build' as an explicit feature-intent signal pattern."""
        content = _read_skill_md()
        assert "I want to build" in content, (
            "Expected SKILL.md to list 'I want to build' as a feature-intent signal pattern "
            "in the Feature Intent Detection section. This is a common natural-language "
            "expression of feature intent that agents must detect."
        )

    def test_feature_intent_section_routes_to_brainstorm(self) -> None:
        """SKILL.md Feature Intent Detection section must direct agents to invoke /dso:brainstorm."""
        content = _read_skill_md()
        assert "brainstorm" in content.lower(), (
            "Expected SKILL.md Feature Intent Detection section to direct agents to invoke "
            "/dso:brainstorm when feature-intent signals are detected. Without this routing "
            "instruction, agents may skip the ideation and validation phase."
        )

    def test_feature_intent_section_is_structural_heading(self) -> None:
        """Feature Intent Detection must appear as a Markdown heading (##, ###) in SKILL.md.

        A section heading makes the guidance discoverable and distinguishes it from
        inline prose. Tests read file content for structural section presence.
        """
        content = _read_skill_md()
        lines = content.splitlines()
        heading_found = any(
            line.startswith("#")
            and ("Feature Intent" in line or "feature intent" in line.lower())
            for line in lines
        )
        assert heading_found, (
            "Expected SKILL.md to contain 'Feature Intent Detection' (or similar) as a "
            "Markdown heading (## or ###). A heading makes the section structurally "
            "discoverable and clearly separates it from other guidance."
        )


class TestSkillMdFeatureIntentSignalPatterns:
    """SKILL.md Feature Intent Detection section must list concrete signal patterns.

    Concrete examples help agents recognize feature-request language even when
    phrased in unfamiliar ways. The section must include at least the three
    canonical patterns and ideally a rationale for routing to brainstorm.
    """

    def test_at_least_three_signal_patterns_present(self) -> None:
        """SKILL.md must list at least three distinct feature-intent signal patterns.

        One or two examples are insufficient to generalize. The minimum is three
        explicit signal patterns so agents can form an accurate recognition heuristic.
        """
        content = _read_skill_md()
        # Check for the three required patterns individually
        required_patterns = ["new feature", "create an epic", "I want to build"]
        found = [p for p in required_patterns if p in content]
        assert len(found) >= 3, (
            f"Expected SKILL.md to contain all three required feature-intent signal "
            f"patterns: {required_patterns}. Found: {found}. "
            "All three patterns must be present to give agents sufficient examples."
        )

    def test_feature_intent_section_not_empty(self) -> None:
        """The Feature Intent Detection section must contain substantive guidance, not just a heading."""
        content = _read_skill_md()
        # Find the section heading line
        lines = content.splitlines()
        section_start = -1
        for i, line in enumerate(lines):
            if line.startswith("#") and (
                "Feature Intent" in line or "feature intent" in line.lower()
            ):
                section_start = i
                break

        assert section_start != -1, (
            "Expected SKILL.md to contain a Feature Intent Detection section heading. "
            "Section not found."
        )

        # Check that there are at least 3 non-empty lines after the heading
        # before the next heading or end of file
        content_lines = []
        for line in lines[section_start + 1 :]:
            if line.startswith("#"):
                break
            if line.strip():
                content_lines.append(line)

        assert len(content_lines) >= 3, (
            f"Feature Intent Detection section in SKILL.md must contain at least "
            f"3 non-empty content lines below the heading. Found: {len(content_lines)}. "
            "The section must include signal patterns and routing guidance."
        )


class TestHookInjectionMdFeatureIntentGuidance:
    """HOOK-INJECTION.md must contain matching feature-intent detection guidance.

    HOOK-INJECTION.md serves a different audience than SKILL.md: it configures
    hook-level injection of the skill at conversation start. Both files must
    contain feature-intent detection guidance so the behavior is consistent
    whether the skill is invoked via Skill tool or injected via hooks.
    """

    def test_hook_injection_contains_feature_intent_guidance(self) -> None:
        """HOOK-INJECTION.md must contain feature-intent detection guidance."""
        content = _read_hook_injection_md()
        assert (
            "Feature Intent" in content
            or "feature intent" in content.lower()
            or "feature-intent" in content.lower()
        ), (
            "Expected HOOK-INJECTION.md to contain feature-intent detection guidance "
            "matching SKILL.md. Both files are used by agents: SKILL.md when the skill "
            "is invoked via Skill tool; HOOK-INJECTION.md when injected at conversation "
            "start via hooks. The guidance must be consistent across both files."
        )

    def test_hook_injection_contains_new_feature_signal(self) -> None:
        """HOOK-INJECTION.md must list 'new feature' as a feature-intent signal pattern."""
        content = _read_hook_injection_md()
        assert "new feature" in content, (
            "Expected HOOK-INJECTION.md to list 'new feature' as a feature-intent signal "
            "pattern. This ensures hook-injected skill instances also recognize this signal."
        )

    def test_hook_injection_contains_create_an_epic_signal(self) -> None:
        """HOOK-INJECTION.md must list 'create an epic' as a feature-intent signal pattern."""
        content = _read_hook_injection_md()
        assert "create an epic" in content, (
            "Expected HOOK-INJECTION.md to list 'create an epic' as a feature-intent signal "
            "pattern. This ensures hook-injected skill instances also recognize this signal."
        )

    def test_hook_injection_contains_i_want_to_build_signal(self) -> None:
        """HOOK-INJECTION.md must list 'I want to build' as a feature-intent signal pattern."""
        content = _read_hook_injection_md()
        assert "I want to build" in content, (
            "Expected HOOK-INJECTION.md to list 'I want to build' as a feature-intent "
            "signal pattern. This ensures hook-injected skill instances recognize this "
            "natural-language expression of feature intent."
        )

    def test_hook_injection_routes_to_brainstorm(self) -> None:
        """HOOK-INJECTION.md feature-intent guidance must direct agents to /dso:brainstorm."""
        content = _read_hook_injection_md()
        assert "brainstorm" in content.lower(), (
            "Expected HOOK-INJECTION.md to direct agents to invoke /dso:brainstorm "
            "when feature-intent signals are detected. This routing instruction must "
            "be present in HOOK-INJECTION.md, not just in SKILL.md."
        )
