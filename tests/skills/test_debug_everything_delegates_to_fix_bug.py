"""Tests asserting debug-everything delegates bug resolution to dso:fix-bug.

TDD spec for task w21-s63d (RED task):
- plugins/dso/skills/debug-everything/SKILL.md Phase 5 must:
  1. Reference 'dso:fix-bug' for individual bug resolution (not fix-task-tdd.md or fix-task-mechanical.md)
  2. Reference 'dso:fix-bug' for cluster resolution
  3. Contain triage-to-scoring-rubric mapping language (severity, scoring rubric, or explicit mapping)
  4. NOT select fix-task-tdd.md or fix-task-mechanical.md in Phase 5 without forward-pointer language

All tests in this file must FAIL (RED) before the SKILL.md changes in the next task.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "debug-everything" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


def _extract_phase5_section(content: str) -> str:
    """Extract the Phase 5 section from the SKILL.md content."""
    # Find Phase 5 start
    phase5_match = re.search(r"## Phase 5:.*?(?=\n## Phase [67])", content, re.DOTALL)
    if phase5_match:
        return phase5_match.group(0)
    # Fallback: return content after Phase 5 heading until end or next major section
    lines = content.split("\n")
    in_phase5 = False
    phase5_lines = []
    for line in lines:
        if re.match(r"## Phase 5:", line):
            in_phase5 = True
        elif re.match(r"## Phase [678]:", line) and in_phase5:
            break
        if in_phase5:
            phase5_lines.append(line)
    return "\n".join(phase5_lines)


def test_phase5_references_dso_fix_bug_for_individual_bugs() -> None:
    """Phase 5 of debug-everything SKILL.md must delegate individual bug resolution to dso:fix-bug.

    This replaces the pattern of selecting fix-task-tdd.md or fix-task-mechanical.md directly.
    Instead, Phase 5 should invoke /dso:fix-bug which encapsulates the routing decision.
    """
    content = _read_skill()
    phase5 = _extract_phase5_section(content)

    assert "/dso:fix-bug" in phase5 or "dso:fix-bug" in phase5, (
        "Expected Phase 5 of debug-everything SKILL.md to reference '/dso:fix-bug' "
        "as the delegation target for individual bug resolution. "
        "Currently Phase 5 uses fix-task-tdd.md and fix-task-mechanical.md directly. "
        "This is a RED test — the SKILL.md does not yet reference dso:fix-bug in Phase 5."
    )


def test_phase5_references_dso_fix_bug_for_cluster_resolution() -> None:
    """Phase 5 of debug-everything SKILL.md must delegate cluster bug resolution to dso:fix-bug.

    When multiple related bugs are resolved together (cluster invocation), Phase 5 should
    invoke /dso:fix-bug with multiple bug IDs rather than using the raw prompt templates.
    """
    content = _read_skill()
    phase5 = _extract_phase5_section(content)

    # Check for both fix-bug delegation AND cluster-related language in Phase 5
    has_fix_bug_ref = "/dso:fix-bug" in phase5 or "dso:fix-bug" in phase5
    has_cluster_context = any(
        phrase in phase5
        for phrase in (
            "cluster",
            "multiple bug",
            "bug cluster",
            "cluster resolution",
        )
    )

    assert has_fix_bug_ref and has_cluster_context, (
        f"Expected Phase 5 to reference 'dso:fix-bug' (found: {has_fix_bug_ref}) "
        f"AND contain cluster resolution language (found: {has_cluster_context}). "
        "Phase 5 should delegate cluster bug resolution to /dso:fix-bug with multiple "
        "bug IDs rather than using raw prompt templates. "
        "This is a RED test — SKILL.md does not yet contain this delegation pattern."
    )


def test_skill_contains_triage_to_scoring_rubric_mapping() -> None:
    """debug-everything SKILL.md must contain triage-to-scoring-rubric mapping language.

    The skill should explicitly map triage tier attributes (e.g., tier number, severity
    classification) to fix-bug scoring rubric dimensions so the handoff to dso:fix-bug
    is structured and predictable.
    """
    content = _read_skill()

    has_scoring_rubric = "scoring rubric" in content.lower()
    has_triage_severity_mapping = any(
        phrase in content
        for phrase in (
            "triage tier",
            "tier attributes",
            "severity score",
            "map triage",
            "triage-to-scoring",
            "triage score",
        )
    )

    assert has_scoring_rubric or has_triage_severity_mapping, (
        "Expected debug-everything SKILL.md to contain triage-to-scoring-rubric mapping "
        "language such as 'scoring rubric', 'triage tier', 'tier attributes', "
        "'severity score', 'map triage', 'triage-to-scoring', or 'triage score'. "
        "This mapping is needed so the handoff from debug-everything triage to "
        "dso:fix-bug's scoring rubric is explicit and structured. "
        "This is a RED test — SKILL.md does not yet contain this mapping language."
    )


def test_phase5_does_not_select_fix_task_templates_without_forward_pointer() -> None:
    """Phase 5 must not select fix-task-tdd.md or fix-task-mechanical.md without a forward pointer.

    After the delegation refactor, Phase 5 should no longer directly select these
    prompt templates. If they appear at all, they must only appear in a forward-pointer
    context (e.g., 'dso:fix-bug uses fix-task-tdd.md internally') not as direct selection.
    """
    content = _read_skill()
    phase5 = _extract_phase5_section(content)

    # Check if Phase 5 directly selects the old templates as primary routing logic
    # A direct selection would be something like:
    # "TDD required → Read ... fix-task-tdd.md"
    # "TDD not required → Read ... fix-task-mechanical.md"
    direct_tdd_selection = re.search(
        r"(TDD required|tdd.*required|Read.*fix-task-tdd\.md)",
        phase5,
        re.IGNORECASE | re.DOTALL,
    )
    direct_mechanical_selection = re.search(
        r"(TDD not required|Read.*fix-task-mechanical\.md)",
        phase5,
        re.IGNORECASE | re.DOTALL,
    )

    # Check if there's a forward pointer (these templates mentioned in context of dso:fix-bug)
    has_forward_pointer = any(
        phrase in phase5
        for phrase in (
            "dso:fix-bug",
            "/dso:fix-bug",
            "delegated to fix-bug",
            "fix-bug handles",
        )
    )

    # If templates are referenced but no forward pointer, that's the failing case
    references_old_templates = bool(direct_tdd_selection or direct_mechanical_selection)

    if references_old_templates and not has_forward_pointer:
        # This is the expected RED state — Phase 5 directly selects templates without delegation
        assert False, (
            "Phase 5 directly selects fix-task-tdd.md or fix-task-mechanical.md "
            "without a forward pointer to dso:fix-bug. "
            f"Direct TDD selection found: {bool(direct_tdd_selection)}, "
            f"Direct mechanical selection found: {bool(direct_mechanical_selection)}, "
            f"Forward pointer to dso:fix-bug found: {has_forward_pointer}. "
            "Phase 5 should delegate to /dso:fix-bug instead of selecting prompt "
            "templates directly. The dso:fix-bug skill encapsulates the TDD vs. "
            "mechanical routing decision. "
            "This is a RED test — SKILL.md must be updated to remove direct template selection."
        )
