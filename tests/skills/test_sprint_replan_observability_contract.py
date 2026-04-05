"""Tests for the REPLAN_TRIGGER/REPLAN_RESOLVED observability signal contract document."""

import pathlib

REPO_ROOT = pathlib.Path(__file__).parent.parent.parent
CONTRACT_FILE = (
    REPO_ROOT / "plugins" / "dso" / "docs" / "contracts" / "replan-observability.md"
)


def _read_contract() -> str:
    return CONTRACT_FILE.read_text()


def test_contract_file_exists():
    """Contract file must exist at the expected path."""
    assert CONTRACT_FILE.exists(), f"Contract file not found at {CONTRACT_FILE}"


def test_contract_defines_replan_trigger_signal():
    """Contract must define the REPLAN_TRIGGER signal."""
    doc = _read_contract()
    assert "REPLAN_TRIGGER" in doc, "Contract does not define the REPLAN_TRIGGER signal"


def test_contract_defines_replan_resolved_signal():
    """Contract must define the REPLAN_RESOLVED signal."""
    doc = _read_contract()
    assert "REPLAN_RESOLVED" in doc, (
        "Contract does not define the REPLAN_RESOLVED signal"
    )


def test_contract_defines_all_four_trigger_types():
    """Contract must define all 4 valid REPLAN_TRIGGER types: drift, failure, validation, review."""
    doc = _read_contract()
    required_types = ["drift", "failure", "validation", "review"]
    for trigger_type in required_types:
        assert trigger_type in doc, (
            f"Contract does not define trigger type '{trigger_type}'"
        )


def test_contract_defines_both_resolved_tiers():
    """Contract must define both REPLAN_RESOLVED tiers: implementation-plan and brainstorm."""
    doc = _read_contract()
    assert "implementation-plan" in doc, (
        "Contract does not define REPLAN_RESOLVED tier 'implementation-plan'"
    )
    assert "brainstorm" in doc, (
        "Contract does not define REPLAN_RESOLVED tier 'brainstorm'"
    )


def test_contract_defines_interactivity_deferred():
    """Contract must define INTERACTIVITY_DEFERRED handling for non-interactive mode."""
    doc = _read_contract()
    assert "INTERACTIVITY_DEFERRED" in doc, (
        "Contract does not define INTERACTIVITY_DEFERRED handling"
    )


def test_contract_includes_example_payloads():
    """Contract must include example payloads for the signals."""
    doc = _read_contract()
    # Should have at least one code block with a REPLAN_TRIGGER example
    assert "REPLAN_TRIGGER:" in doc, (
        "Contract does not include example REPLAN_TRIGGER payload"
    )
    assert "REPLAN_RESOLVED:" in doc, (
        "Contract does not include example REPLAN_RESOLVED payload"
    )


def test_contract_specifies_trigger_written_before_action():
    """Contract must specify that REPLAN_TRIGGER is written BEFORE the re-planning action."""
    doc = _read_contract()
    doc_lower = doc.lower()
    # The contract should say trigger is written before action
    assert "before" in doc_lower, (
        "Contract does not specify that REPLAN_TRIGGER is written before the re-planning action"
    )


def test_contract_specifies_resolved_written_after_action():
    """Contract must specify that REPLAN_RESOLVED is written AFTER successful re-planning."""
    doc = _read_contract()
    doc_lower = doc.lower()
    assert "after" in doc_lower, (
        "Contract does not specify that REPLAN_RESOLVED is written after re-planning"
    )


def test_contract_specifies_epic_ticket_location():
    """Contract must specify that signals are written to epic ticket comments."""
    doc = _read_contract()
    assert "epic" in doc.lower(), (
        "Contract does not specify epic ticket as the location for signals"
    )
    assert "comment" in doc.lower(), (
        "Contract does not specify ticket comments as the write location"
    )
