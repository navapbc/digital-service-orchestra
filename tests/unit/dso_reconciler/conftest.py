"""Shared pytest fixtures for dso_reconciler unit tests.

Divergence scenarios for all 3 resolution classes in conflict_resolver.py.
"""

from __future__ import annotations

import pytest


@pytest.fixture
def state_divergence():
    """State-class divergence: local 'In Progress', remote 'Done'."""
    return {"field": "status", "local": "In Progress", "remote": "Done"}


@pytest.fixture
def additive_divergence():
    """Additive-class divergence: local description A, remote description B."""
    return {
        "field": "description",
        "local": "Local description content A",
        "remote": "Remote description content B",
    }


@pytest.fixture
def set_divergence():
    """Set-class divergence: local {X,Y}, remote {Y,Z}."""
    return {
        "field": "labels",
        "local": ["X", "Y"],
        "remote": ["Y", "Z"],
        "expected_union": {"X", "Y", "Z"},
    }
