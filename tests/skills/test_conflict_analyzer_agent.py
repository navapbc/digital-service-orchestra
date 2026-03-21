"""Tests for the conflict-analyzer agent definition.

TDD spec (RED before implementation, GREEN after):
- plugins/dso/agents/conflict-analyzer.md must exist with valid YAML frontmatter
- The agent definition must contain TRIVIAL/SEMANTIC/AMBIGUOUS classification criteria
- The agent definition must contain per-file output format with all required fields
- resolve-conflicts SKILL.md must reference dso:conflict-analyzer subagent_type
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT_FILE = REPO_ROOT / "plugins" / "dso" / "agents" / "conflict-analyzer.md"
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "resolve-conflicts" / "SKILL.md"


def _read_agent() -> str:
    return AGENT_FILE.read_text()


def _read_skill() -> str:
    return SKILL_FILE.read_text()


# ─── Agent file existence ────────────────────────────────────────────────────


def test_conflict_analyzer_agent_file_exists() -> None:
    """plugins/dso/agents/conflict-analyzer.md must exist at the expected path."""
    assert AGENT_FILE.exists(), (
        f"Expected conflict-analyzer agent definition to exist at {AGENT_FILE}. "
        "This is a RED test — the file does not exist yet and must be created."
    )


# ─── YAML frontmatter ────────────────────────────────────────────────────────


def test_conflict_analyzer_has_yaml_frontmatter() -> None:
    """Agent file must start with YAML frontmatter delimited by ---."""
    content = _read_agent()
    assert content.startswith("---"), (
        "conflict-analyzer.md must start with YAML frontmatter (---). "
        "Expected format: ---\\nname: conflict-analyzer\\n..."
    )
    assert "---" in content[3:], (
        "conflict-analyzer.md must have a closing --- for the YAML frontmatter block."
    )


def test_conflict_analyzer_frontmatter_name_field() -> None:
    """YAML frontmatter must contain name: conflict-analyzer."""
    content = _read_agent()
    assert "name: conflict-analyzer" in content, (
        "conflict-analyzer.md frontmatter must contain 'name: conflict-analyzer'. "
        "This name is used by callers dispatching via subagent_type: dso:conflict-analyzer."
    )


def test_conflict_analyzer_frontmatter_model_field() -> None:
    """YAML frontmatter must contain model: sonnet."""
    content = _read_agent()
    assert "model: sonnet" in content, (
        "conflict-analyzer.md frontmatter must contain 'model: sonnet'. "
        "Conflict resolution requires code understanding but not architectural reasoning."
    )


def test_conflict_analyzer_frontmatter_tools_field() -> None:
    """YAML frontmatter must contain a tools list with Bash, Read, Glob, Grep."""
    content = _read_agent()
    assert "tools:" in content, (
        "conflict-analyzer.md frontmatter must contain a 'tools:' field."
    )
    for tool in ("Bash", "Read", "Glob", "Grep"):
        assert tool in content, (
            f"conflict-analyzer.md frontmatter tools list must include '{tool}'. "
            f"These tools are needed for conflict analysis (reading files, running git commands)."
        )


# ─── Classification criteria ────────────────────────────────────────────────


def test_conflict_analyzer_contains_trivial_classification() -> None:
    """Agent definition must contain TRIVIAL classification criteria."""
    content = _read_agent()
    assert "TRIVIAL" in content, (
        "conflict-analyzer.md must contain 'TRIVIAL' classification criteria. "
        "TRIVIAL conflicts are auto-resolvable (import ordering, non-overlapping additions, etc.)."
    )


def test_conflict_analyzer_contains_semantic_classification() -> None:
    """Agent definition must contain SEMANTIC classification criteria."""
    content = _read_agent()
    assert "SEMANTIC" in content, (
        "conflict-analyzer.md must contain 'SEMANTIC' classification criteria. "
        "SEMANTIC conflicts are resolvable but require human review."
    )


def test_conflict_analyzer_contains_ambiguous_classification() -> None:
    """Agent definition must contain AMBIGUOUS classification criteria."""
    content = _read_agent()
    assert "AMBIGUOUS" in content, (
        "conflict-analyzer.md must contain 'AMBIGUOUS' classification criteria. "
        "AMBIGUOUS conflicts cannot be resolved without human decision."
    )


def test_conflict_analyzer_all_three_classifications_present() -> None:
    """Agent definition must contain all three classification types."""
    content = _read_agent()
    missing = [c for c in ("TRIVIAL", "SEMANTIC", "AMBIGUOUS") if c not in content]
    assert not missing, (
        f"conflict-analyzer.md is missing classification types: {missing}. "
        "All three (TRIVIAL, SEMANTIC, AMBIGUOUS) must be defined."
    )


# ─── Per-file output format ──────────────────────────────────────────────────


def test_conflict_analyzer_contains_file_path_output_field() -> None:
    """Agent definition must specify file path as an output field."""
    content = _read_agent()
    assert "file path" in content.lower() or "file_path" in content, (
        "conflict-analyzer.md must specify 'file path' or 'file_path' as a per-file output field."
    )


def test_conflict_analyzer_contains_classification_output_field() -> None:
    """Agent definition must specify classification as an output field."""
    content = _read_agent()
    # Classification criteria presence already tested; also confirm it's in output schema
    has_output_section = (
        "output" in content.lower()
        or "Output" in content
        or "OUTPUT" in content
        or "classification" in content
    )
    assert has_output_section, (
        "conflict-analyzer.md must specify a classification output field."
    )


def test_conflict_analyzer_contains_proposed_resolution_output_field() -> None:
    """Agent definition must specify proposed resolution as an output field."""
    content = _read_agent()
    assert "resolution" in content.lower(), (
        "conflict-analyzer.md must specify 'resolution' as a per-file output field. "
        "Callers need proposed resolution code to apply or present to the user."
    )


def test_conflict_analyzer_contains_explanation_output_field() -> None:
    """Agent definition must specify explanation as an output field."""
    content = _read_agent()
    assert "explanation" in content.lower(), (
        "conflict-analyzer.md must specify 'explanation' as a per-file output field. "
        "Callers need explanation of what each side intended to present to users."
    )


def test_conflict_analyzer_contains_confidence_output_field() -> None:
    """Agent definition must specify confidence as an output field."""
    content = _read_agent()
    assert "confidence" in content.lower(), (
        "conflict-analyzer.md must specify 'confidence' as a per-file output field."
    )


def test_conflict_analyzer_confidence_levels_defined() -> None:
    """Agent definition must define HIGH/MEDIUM/LOW confidence levels."""
    content = _read_agent()
    for level in ("HIGH", "MEDIUM", "LOW"):
        assert level in content, (
            f"conflict-analyzer.md must define confidence level '{level}'. "
            "Callers use confidence to decide whether to auto-resolve or escalate."
        )


# ─── resolve-conflicts SKILL.md references ──────────────────────────────────


def test_resolve_conflicts_references_conflict_analyzer_agent() -> None:
    """resolve-conflicts/SKILL.md must reference dso:conflict-analyzer subagent_type."""
    content = _read_skill()
    assert "conflict-analyzer" in content, (
        "resolve-conflicts/SKILL.md must reference 'conflict-analyzer' to dispatch "
        "conflict analysis via the dedicated dso:conflict-analyzer agent."
    )


def test_resolve_conflicts_uses_subagent_type_dispatch() -> None:
    """resolve-conflicts/SKILL.md must use subagent_type dispatch for conflict analysis."""
    content = _read_skill()
    assert "subagent_type" in content, (
        "resolve-conflicts/SKILL.md must use 'subagent_type' dispatch to invoke "
        "dso:conflict-analyzer instead of embedding the classification prompt inline."
    )


def test_resolve_conflicts_dispatches_via_named_agent() -> None:
    """resolve-conflicts/SKILL.md Step 2 must dispatch via dso:conflict-analyzer."""
    content = _read_skill()
    # Check for the qualified agent name in dispatch context
    assert "dso:conflict-analyzer" in content, (
        "resolve-conflicts/SKILL.md must reference 'dso:conflict-analyzer' as the "
        "subagent_type value. This replaces the inline classification prompt in Step 2."
    )


def test_resolve_conflicts_does_not_embed_full_inline_prompt() -> None:
    """resolve-conflicts/SKILL.md Step 2 should not embed full inline classification criteria.

    After extracting to the agent definition, the inline classification prompt block
    (TRIVIAL/SEMANTIC/AMBIGUOUS criteria listed within the skill) should be removed,
    replaced by a reference to the dso:conflict-analyzer agent dispatch.
    The CONFLICT CLASSIFICATIONS header from the old inline prompt should be gone.
    """
    content = _read_skill()
    # The old inline prompt had this exact header inside a code block
    # After extraction, it should no longer appear in the skill
    assert "CONFLICT CLASSIFICATIONS:" not in content, (
        "resolve-conflicts/SKILL.md should not embed 'CONFLICT CLASSIFICATIONS:' inline "
        "after extraction. Classification criteria belong in conflict-analyzer.md."
    )
