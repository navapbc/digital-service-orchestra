"""Tests for completion-verifier enforcement in sprint SKILL.md and CLAUDE.md.

Bug ce1a-bf7f: Orchestrator skips completion-verifier sub-agent dispatch at
epic closure (Phase 7 Step 0.75) and story closure (Phase 6 Step 10a).

Root cause: Fallback clauses frame the verifier as "not a hard blocker,"
no CLAUDE.md "Never Do" rule exists, and no MUST language enforces dispatch.

These tests verify the instruction-level fix:
1. CLAUDE.md contains a "Never Do" rule prohibiting inline completion verification
2. SKILL.md Step 10a uses MUST language for dispatch (not soft imperative)
3. SKILL.md Step 0.75 uses MUST language for dispatch (not soft imperative)
4. Fallback clauses are scoped to technical failures only (no "not a hard blocker")
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"
CLAUDE_MD = REPO_ROOT / "CLAUDE.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def _read_claude_md() -> str:
    return CLAUDE_MD.read_text()


def _extract_step_10a(content: str) -> str:
    """Extract Step 10a section from SKILL.md."""
    pattern = re.compile(
        r"### Step 10a:.*?(?=\n### |\n## |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def _extract_step_075(content: str) -> str:
    """Extract Step 0.75 section from SKILL.md."""
    pattern = re.compile(
        r"### Step 0\.75:.*?(?=\n### |\n## |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def _extract_never_do_section(content: str) -> str:
    """Extract the 'Never Do These' section from CLAUDE.md."""
    pattern = re.compile(
        r"### Never Do These.*?(?=\n### |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def test_claude_md_has_never_skip_completion_verifier_rule() -> None:
    """CLAUDE.md 'Never Do These' must prohibit skipping completion-verifier dispatch."""
    content = _read_claude_md()
    never_do = _extract_never_do_section(content)

    assert never_do, (
        "Expected to find a 'Never Do These' section in CLAUDE.md but none was found."
    )

    # Must mention completion-verifier in a Never Do rule
    assert re.search(r"completion.verifier", never_do, re.IGNORECASE), (
        "Expected CLAUDE.md 'Never Do These' section to contain a rule about "
        "the completion-verifier. The orchestrator needs an explicit prohibition "
        "against skipping the completion-verifier dispatch or substituting inline "
        "verification at story/epic closure."
    )

    # Must prohibit inline verification as a substitute
    assert re.search(
        r"inline.verif|manual.verif|substitut|orchestrator.*verify",
        never_do,
        re.IGNORECASE,
    ), (
        "Expected CLAUDE.md 'Never Do These' rule to explicitly prohibit inline/manual "
        "verification as a substitute for the completion-verifier sub-agent dispatch. "
        "The orchestrator rationalizes skipping the agent by performing its own checks."
    )


def test_step_10a_uses_must_language() -> None:
    """Step 10a must use MUST language for completion-verifier dispatch."""
    content = _read_skill()
    step_10a = _extract_step_10a(content)

    assert step_10a, "Expected to find Step 10a in SKILL.md but none was found."

    # Must contain mandatory dispatch language (MUST, REQUIRED, or MANDATORY)
    assert re.search(
        r"\bMUST\b.*dispatch.*completion.verifier"
        r"|\bMUST\b.*completion.verifier"
        r"|\bMANDATORY\b.*completion.verifier"
        r"|\bREQUIRED\b.*completion.verifier",
        step_10a,
        re.IGNORECASE,
    ), (
        "Expected Step 10a to use MUST/MANDATORY/REQUIRED language for the "
        "completion-verifier dispatch. Current soft imperative ('dispatch the "
        "completion verifier') allows the orchestrator to rationalize skipping it."
    )


def test_step_075_uses_must_language() -> None:
    """Step 0.75 must use MUST language for completion-verifier dispatch."""
    content = _read_skill()
    step_075 = _extract_step_075(content)

    assert step_075, "Expected to find Step 0.75 in SKILL.md but none was found."

    # Must contain mandatory dispatch language
    assert re.search(
        r"\bMUST\b.*dispatch.*completion.verifier"
        r"|\bMUST\b.*completion.verifier"
        r"|\bMANDATORY\b.*completion.verifier"
        r"|\bREQUIRED\b.*completion.verifier",
        step_075,
        re.IGNORECASE,
    ), (
        "Expected Step 0.75 to use MUST/MANDATORY/REQUIRED language for the "
        "completion-verifier dispatch. Current soft imperative allows the "
        "orchestrator to rationalize skipping it."
    )


def test_fallback_clauses_scoped_to_technical_failures() -> None:
    """Fallback clauses must NOT contain 'not a hard blocker' language."""
    content = _read_skill()
    step_10a = _extract_step_10a(content)
    step_075 = _extract_step_075(content)

    for label, section in [("Step 10a", step_10a), ("Step 0.75", step_075)]:
        assert section, f"Expected to find {label} in SKILL.md but none was found."

        # Must NOT contain "not a hard blocker" — this is the rationalization pathway
        assert not re.search(r"not a hard blocker", section, re.IGNORECASE), (
            f"Expected {label} to NOT contain the phrase 'not a hard blocker'. "
            "This language frames the completion-verifier dispatch as optional, "
            "giving the orchestrator a rationalization pathway to skip it entirely. "
            "The Fallback clause should be scoped to technical failures only "
            "(timeout, unparseable JSON) without implying the step itself is optional."
        )
