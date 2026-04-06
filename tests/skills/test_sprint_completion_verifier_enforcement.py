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


def test_hard_gate_before_step_10a() -> None:
    """A HARD-GATE must precede Step 10a to block Step 11 until verifier completes.

    Bug ed1e-951b: MANDATORY labels are advisory text that the orchestrator
    rationalizes past. HARD-GATE XML blocks are structural interrupts that
    resist Multi-Step Reasoning Drift.
    """
    content = _read_skill()
    step_10a_pos = content.find("### Step 10a:")
    assert step_10a_pos > 0, "Step 10a not found in SKILL.md"

    # Find the HARD-GATE that must appear before Step 10a
    preceding = content[:step_10a_pos]
    # The HARD-GATE must be in the section between the last ### heading and Step 10a
    last_gate = preceding.rfind("<HARD-GATE>")
    last_gate_close = preceding.rfind("</HARD-GATE>")
    assert last_gate > 0 and last_gate_close > last_gate, (
        "Expected a <HARD-GATE> block before Step 10a that blocks forward "
        "progress until completion-verifier dispatch completes. MANDATORY "
        "labels are insufficient — they are advisory text that the orchestrator "
        "rationalizes past during Multi-Step Reasoning Drift."
    )

    gate_content = preceding[last_gate:last_gate_close]
    assert re.search(r"Step 10a|completion.verifier", gate_content, re.IGNORECASE), (
        "HARD-GATE before Step 10a must reference Step 10a or completion-verifier."
    )


def test_hard_gate_at_phase_6_entry() -> None:
    """A HARD-GATE must appear at Phase 6 entry to block all steps until Step 0.75 runs.

    Bug ed1e-951b: Step 0.75 as a numbered step inside Phase 6 can be
    rationalized past. A HARD-GATE at the phase boundary forces the verifier
    to run before any Phase 6 progress.
    """
    content = _read_skill()
    phase_6_pos = content.find("## Phase 6: Post-Primary Ticket Validation")
    if phase_6_pos < 0:
        phase_6_pos = content.find("## Phase 6: Post-Epic Validation")
    assert phase_6_pos > 0, "Phase 6 not found in SKILL.md"

    # HARD-GATE must appear between Phase 6 header and first ### step
    phase_6_section = content[phase_6_pos:]
    first_step = re.search(r"\n### ", phase_6_section)
    assert first_step, "No steps found in Phase 6"

    phase_6_preamble = phase_6_section[: first_step.start()]
    assert "<HARD-GATE>" in phase_6_preamble and "</HARD-GATE>" in phase_6_preamble, (
        "Expected a <HARD-GATE> block in the Phase 6 preamble (between the "
        "Phase 6 heading and the first ### step). Without this gate, the "
        "orchestrator enters Phase 6 with momentum from 'all tasks closed' "
        "and rationalizes past Step 0.75."
    )

    gate_start = phase_6_preamble.find("<HARD-GATE>")
    gate_end = phase_6_preamble.find("</HARD-GATE>")
    gate_content = phase_6_preamble[gate_start:gate_end]
    assert re.search(r"Step 0\.75|completion.verifier", gate_content, re.IGNORECASE), (
        "Phase 6 HARD-GATE must reference Step 0.75 or completion-verifier."
    )


def test_no_conflicting_immediately_directive() -> None:
    """No 'continue IMMEDIATELY with Step 11' directive should exist near Step 10a.

    Bug ed1e-951b: The prior 'CONTROL FLOW WARNING: continue IMMEDIATELY
    with Step 11' directive directly contradicted the MANDATORY STOP requiring
    Step 10a first, enabling Multi-Step Reasoning Drift.
    """
    content = _read_skill()
    step_10a_pos = content.find("### Step 10a:")
    assert step_10a_pos > 0, "Step 10a not found in SKILL.md"

    # Check the 500 chars before Step 10a for conflicting directives
    preceding = content[max(0, step_10a_pos - 500) : step_10a_pos]
    assert not re.search(r"continue\s+IMMEDIATELY\s+with\s+Step\s+11", preceding), (
        "Found a 'continue IMMEDIATELY with Step 11' directive before Step 10a. "
        "This directive contradicts the HARD-GATE requiring Step 10a to complete "
        "before Step 11 and enables Multi-Step Reasoning Drift."
    )
