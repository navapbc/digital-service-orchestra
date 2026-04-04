"""Tests for the sprint cascade replan protocol configuration and documentation."""

import pathlib

REPO_ROOT = pathlib.Path(__file__).parent.parent.parent
DSO_CONFIG = REPO_ROOT / ".claude" / "dso-config.conf"
CASCADE_DOC = (
    REPO_ROOT / "plugins" / "dso" / "docs" / "designs" / "cascade-replan-protocol.md"
)


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
