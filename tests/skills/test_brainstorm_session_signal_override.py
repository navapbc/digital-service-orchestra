"""Tests for the session-signal override thresholds in brainstorm/SKILL.md.

Bug (LLM-behavioral): brainstorm/SKILL.md lacked a session-signal override that
forces COMPLEX classification when success_criteria_count >= 7 or
scenario_survivor_count >= 10, regardless of the evaluator's output.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BRAINSTORM_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "brainstorm" / "SKILL.md"


def _read_brainstorm() -> str:
    return BRAINSTORM_MD.read_text()


def _extract_step4b_section(content: str) -> str:
    """Extract Step 4b section between its heading and the next heading."""
    pattern = re.compile(
        r"#### Step 4b:.*?(?=\n#### |\n### |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def test_brainstorm_step4b_has_session_signal_override() -> None:
    """Step 4b in brainstorm/SKILL.md must contain a session-signal override section.

    Without this override, the evaluator's MODERATE/TRIVIAL classification can
    route large, complex epics (high SC count or scenario density) to lightweight
    workflows, bypassing full preplanning.
    """
    content = _read_brainstorm()
    step4b = _extract_step4b_section(content)

    assert step4b, (
        "Expected to find a 'Step 4b:' section in brainstorm/SKILL.md but none was found. "
        "Check that the heading matches '#### Step 4b: ...'."
    )

    has_override = re.search(
        r"session.signal override|session signal override",
        step4b,
        re.IGNORECASE,
    )
    assert has_override, (
        "Expected Step 4b of brainstorm/SKILL.md to contain a 'session-signal override' "
        "section that forces COMPLEX classification based on SC count or scenario density. "
        "Without it, the evaluator's output is the sole classification signal."
    )


def test_brainstorm_session_signal_override_threshold_sc_count() -> None:
    """The session-signal override must specify success_criteria_count >= 7 forces COMPLEX."""
    content = _read_brainstorm()
    step4b = _extract_step4b_section(content)

    assert step4b, "Expected to find a 'Step 4b:' section in brainstorm/SKILL.md."

    has_sc_threshold = re.search(
        r"success_criteria_count\s*[≥>=]+\s*7"
        r"|SC\s*[≥>=]+\s*7"
        r"|success criteria.*?[≥>=]\s*7"
        r"|7.*?success criteria",
        step4b,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_sc_threshold, (
        "Expected the session-signal override in brainstorm/SKILL.md Step 4b to specify "
        "that success_criteria_count >= 7 forces COMPLEX classification. "
        "The threshold of 7 enforces the spec norm of 3-6 success criteria per epic."
    )


def test_brainstorm_session_signal_override_threshold_scenario_count() -> None:
    """The session-signal override must specify scenario_survivor_count >= 10 forces COMPLEX."""
    content = _read_brainstorm()
    step4b = _extract_step4b_section(content)

    assert step4b, "Expected to find a 'Step 4b:' section in brainstorm/SKILL.md."

    has_scenario_threshold = re.search(
        r"scenario_survivor_count\s*[≥>=]+\s*10"
        r"|scenarios?\s*[≥>=]+\s*10"
        r"|scenario.*?[≥>=]\s*10"
        r"|10.*?scenario",
        step4b,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_scenario_threshold, (
        "Expected the session-signal override in brainstorm/SKILL.md Step 4b to specify "
        "that scenario_survivor_count >= 10 forces COMPLEX classification. "
        "High scenario density signals unresolved edge-case complexity requiring full preplanning."
    )


def test_brainstorm_session_signal_override_routes_to_complex() -> None:
    """The session-signal override must route to COMPLEX (not MODERATE) when triggered."""
    content = _read_brainstorm()
    step4b = _extract_step4b_section(content)

    assert step4b, "Expected to find a 'Step 4b:' section in brainstorm/SKILL.md."

    # Must mention COMPLEX as the forced outcome
    has_complex_outcome = re.search(
        r"override.*?COMPLEX|COMPLEX.*?override|force.*?COMPLEX|COMPLEX.*?force"
        r"|classify.*?COMPLEX.*?override|override.*?classify.*?COMPLEX",
        step4b,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_complex_outcome, (
        "Expected the session-signal override in brainstorm/SKILL.md Step 4b to specify "
        "COMPLEX as the forced classification outcome. An override that doesn't name "
        "COMPLEX doesn't provide a clear routing signal."
    )
