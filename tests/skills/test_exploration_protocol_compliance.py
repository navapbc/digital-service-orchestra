"""Compliance tests for exploration-decomposition.md protocol.

TDD spec for task f5a5-dfa5 (RED task):
- plugins/dso/skills/shared/prompts/exploration-decomposition.md must exist and contain:
  1. SINGLE_SOURCE and MULTI_SOURCE classification labels
  2. DECOMPOSE_RECOMMENDED escape hatch signal
  3. Re-decomposition bounded to 1 level
- The protocol must be referenced in three key skill SKILL.md files:
  4. plugins/dso/skills/brainstorm/SKILL.md
  5. plugins/dso/skills/fix-bug/SKILL.md
  6. plugins/dso/skills/implementation-plan/SKILL.md
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PROTOCOL_FILE = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "shared"
    / "prompts"
    / "exploration-decomposition.md"
)
BRAINSTORM_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "brainstorm" / "SKILL.md"
FIX_BUG_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"
IMPL_PLAN_SKILL = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "implementation-plan" / "SKILL.md"
)


def _read_protocol() -> str:
    return PROTOCOL_FILE.read_text()


# ---------------------------------------------------------------------------
# Protocol file existence
# ---------------------------------------------------------------------------


def test_exploration_decomposition_protocol_file_exists() -> None:
    """The exploration-decomposition.md file must exist at the expected shared prompts path."""
    assert PROTOCOL_FILE.exists(), (
        f"Expected exploration-decomposition protocol to exist at {PROTOCOL_FILE}. "
        "This is a RED test — the file does not exist yet and must be created."
    )


# ---------------------------------------------------------------------------
# Required classification labels
# ---------------------------------------------------------------------------


def test_protocol_contains_single_source_classification() -> None:
    """Protocol must define a SINGLE_SOURCE classification label."""
    content = _read_protocol()
    assert "SINGLE_SOURCE" in content, (
        "Expected exploration-decomposition.md to contain 'SINGLE_SOURCE' as a "
        "classification label for single-source exploration tasks."
    )


def test_protocol_contains_multi_source_classification() -> None:
    """Protocol must define a MULTI_SOURCE classification label."""
    content = _read_protocol()
    assert "MULTI_SOURCE" in content, (
        "Expected exploration-decomposition.md to contain 'MULTI_SOURCE' as a "
        "classification label for multi-source exploration tasks."
    )


# ---------------------------------------------------------------------------
# Escape hatch signal
# ---------------------------------------------------------------------------


def test_protocol_contains_decompose_recommended_signal() -> None:
    """Protocol must define the DECOMPOSE_RECOMMENDED escape hatch signal."""
    content = _read_protocol()
    assert "DECOMPOSE_RECOMMENDED" in content, (
        "Expected exploration-decomposition.md to contain 'DECOMPOSE_RECOMMENDED' "
        "as the escape hatch signal that triggers sub-task decomposition."
    )


# ---------------------------------------------------------------------------
# Re-decomposition depth bound
# ---------------------------------------------------------------------------


def test_protocol_bounds_redecomposition_to_one_level() -> None:
    """Protocol must state that re-decomposition is bounded to a single level."""
    content = _read_protocol()
    has_bound = any(
        phrase in content
        for phrase in (
            "1 level",
            "one level",
            "max 1",
            "bound",
        )
    )
    assert has_bound, (
        "Expected exploration-decomposition.md to bound re-decomposition depth "
        "(e.g., '1 level', 'one level', 'max 1', or 'bound'). "
        "Unbounded recursive decomposition must be prohibited."
    )


# ---------------------------------------------------------------------------
# Skill reference checks — brainstorm
# ---------------------------------------------------------------------------


def test_brainstorm_skill_references_exploration_decomposition() -> None:
    """brainstorm/SKILL.md must reference exploration-decomposition.md."""
    content = BRAINSTORM_SKILL.read_text()
    assert "exploration-decomposition" in content, (
        "Expected plugins/dso/skills/brainstorm/SKILL.md to reference "
        "'exploration-decomposition' (the shared exploration protocol). "
        "Add a reference so brainstorm consumers know the protocol exists."
    )


# ---------------------------------------------------------------------------
# Skill reference checks — fix-bug
# ---------------------------------------------------------------------------


def test_fix_bug_skill_references_exploration_decomposition() -> None:
    """fix-bug/SKILL.md must reference exploration-decomposition.md."""
    content = FIX_BUG_SKILL.read_text()
    assert "exploration-decomposition" in content, (
        "Expected plugins/dso/skills/fix-bug/SKILL.md to reference "
        "'exploration-decomposition' (the shared exploration protocol). "
        "Add a reference so fix-bug consumers know the protocol exists."
    )


# ---------------------------------------------------------------------------
# Skill reference checks — implementation-plan
# ---------------------------------------------------------------------------


def test_implementation_plan_skill_references_exploration_decomposition() -> None:
    """implementation-plan/SKILL.md must reference exploration-decomposition.md."""
    content = IMPL_PLAN_SKILL.read_text()
    assert "exploration-decomposition" in content, (
        "Expected plugins/dso/skills/implementation-plan/SKILL.md to reference "
        "'exploration-decomposition' (the shared exploration protocol). "
        "Add a reference so implementation-plan consumers know the protocol exists."
    )
