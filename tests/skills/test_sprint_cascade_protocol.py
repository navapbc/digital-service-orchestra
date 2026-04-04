"""Tests for the sprint cascade replan protocol configuration and documentation."""

import pathlib

REPO_ROOT = pathlib.Path(__file__).parent.parent.parent
DSO_CONFIG = REPO_ROOT / ".claude" / "dso-config.conf"
CASCADE_DOC = (
    REPO_ROOT / "plugins" / "dso" / "docs" / "designs" / "cascade-replan-protocol.md"
)
SPRINT_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"


def _read_config() -> str:
    return DSO_CONFIG.read_text()


def _read_cascade_doc() -> str:
    return CASCADE_DOC.read_text()


def test_cascade_max_replan_cycles_config_key_exists():
    """dso-config.conf must contain sprint.max_replan_cycles."""
    config = _read_config()
    assert "sprint.max_replan_cycles" in config, (
        "sprint.max_replan_cycles key not found in .claude/dso-config.conf"
    )


def test_cascade_protocol_doc_exists():
    """cascade-replan-protocol.md must exist in plugins/dso/docs/designs/."""
    assert CASCADE_DOC.exists(), f"Cascade protocol doc not found at {CASCADE_DOC}"


def test_cascade_protocol_documents_context_invalidation():
    """Cascade protocol doc must document preplanning context file invalidation."""
    doc = _read_cascade_doc()
    assert "preplanning-context" in doc or (
        "context" in doc and "invalidat" in doc.lower()
    ), (
        "cascade-replan-protocol.md does not document preplanning context file invalidation "
        "(expected reference to preplanning-context file or context invalidation)"
    )


def test_cascade_protocol_documents_max_cycles_termination():
    """Cascade protocol doc must document max_replan_cycles termination condition."""
    doc = _read_cascade_doc()
    assert (
        "max_replan_cycles" in doc
        or "cycle cap" in doc.lower()
        or ("max" in doc.lower() and "cycles" in doc.lower())
    ), (
        "cascade-replan-protocol.md does not document max_replan_cycles termination condition"
    )


def test_cascade_protocol_documents_entry_exit_conditions():
    """Cascade protocol doc must document both entry and exit conditions."""
    doc = _read_cascade_doc()
    doc_lower = doc.lower()
    assert "entry" in doc_lower, (
        "cascade-replan-protocol.md does not document entry conditions"
    )
    assert "exit" in doc_lower, (
        "cascade-replan-protocol.md does not document exit conditions"
    )


def _read_sprint_skill() -> str:
    return SPRINT_SKILL.read_text()


def _phase3_step2_window() -> str:
    """Return the Phase 3 Step 2 implementation planning section of sprint SKILL.md.

    NOTE: the start/end markers are structural anchors — must match SKILL.md headings exactly.
    If either heading changes, update the marker here to match.
    """
    skill = _read_sprint_skill()
    start_marker = "#### Step 2: Run Implementation Planning"
    end_marker = "#### Step 3: Continue to Classification"
    start = skill.find(start_marker)
    end = skill.find(end_marker, start)
    assert start != -1, f"Could not find '{start_marker}' in SKILL.md"
    assert end != -1, f"Could not find '{end_marker}' in SKILL.md"
    return skill[start:end]


def _d_replan_collect_window() -> str:
    """Return just the d-replan-collect subsection from Phase 3 Step 2."""
    window = _phase3_step2_window()
    start_marker = "d-replan-collect."
    end_marker = "e. **Post-layer-batch ticket validation**"
    start = window.find(start_marker)
    end = window.find(end_marker, start)
    assert start != -1, "Could not find 'd-replan-collect.' section in Phase 3 Step 2"
    assert end != -1, "Could not find end of d-replan-collect section"
    return window[start:end]


def test_phase3_step2_handles_replan_escalate_signal():
    """Sprint SKILL.md Phase 3 Step 2 STATUS parse block must handle REPLAN_ESCALATE."""
    window = _phase3_step2_window()
    assert "REPLAN_ESCALATE" in window, (
        "Sprint SKILL.md Phase 3 Step 2 has no branch for REPLAN_ESCALATE signal from "
        "implementation-plan. Add a case to the 'parse STATUS' block (step d) that detects "
        "'REPLAN_ESCALATE: brainstorm EXPLANATION:' and routes per cascade-replan-protocol.md."
    )


def test_phase3_step2_replan_escalate_requires_user_confirmation():
    """d-replan-collect must document 'Wait for user input' before entering cascade."""
    collect = _d_replan_collect_window()
    assert "Wait for user input" in collect or "Wait for the user" in collect, (
        "Sprint SKILL.md d-replan-collect must document 'Wait for user input' — "
        "cascade-replan-protocol.md requires user confirmation before each cascade iteration."
    )


def test_phase3_step2_replan_escalate_tracks_cycle_count():
    """d-replan-collect must check the cycle cap BEFORE presenting user options."""
    collect = _d_replan_collect_window()
    assert "max_replan_cycles" in collect, (
        "Sprint SKILL.md d-replan-collect must reference max_replan_cycles for cycle cap check."
    )
    # Verify cap check appears before the Options menu (per cascade-replan-protocol.md ordering)
    cap_idx = collect.find("max_replan_cycles")
    options_idx = collect.find("Options:")
    assert cap_idx != -1 and options_idx != -1, (
        "d-replan-collect must contain both 'max_replan_cycles' and 'Options:' — "
        "cycle cap check must precede the user options menu."
    )
    assert cap_idx < options_idx, (
        "Sprint SKILL.md d-replan-collect must check cycle cap (max_replan_cycles) BEFORE "
        "presenting user options — per cascade-replan-protocol.md pseudocode ordering."
    )


def test_phase3_step2_replan_escalate_handles_malformed_signal():
    """REPLAN_ESCALATE branch must document malformed-signal fallback to STATUS:blocked."""
    window = _phase3_step2_window()
    replan_idx = window.find("REPLAN_ESCALATE: brainstorm EXPLANATION:")
    assert replan_idx != -1, (
        "Sprint SKILL.md Phase 3 Step 2 has no REPLAN_ESCALATE branch."
    )
    nearby = window[replan_idx : replan_idx + 800]
    assert "malformed" in nearby.lower() or "STATUS:blocked" in nearby, (
        "Sprint SKILL.md Phase 3 Step 2 REPLAN_ESCALATE branch must document the "
        "malformed-signal guard: if the signal is present but missing EXPLANATION: or has "
        "empty explanation text, fall back to STATUS:blocked (per replan-escalate-signal.md "
        "Failure Contract)."
    )
