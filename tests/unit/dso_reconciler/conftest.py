"""Shared pytest fixtures for dso_reconciler unit tests.

Divergence scenarios for all 3 resolution classes in conflict_resolver.py.

Test-loading convention
-----------------------
Tests in this directory load modules under test via
``importlib.util.spec_from_file_location`` rather than ordinary ``import``
statements. This is the established pattern across the wider reconciler test
tree (see ``tests/scripts/test_pre_cutover.py``,
``tests/scripts/test_capability_check.py``,
``tests/scripts/test_forward_compat_probe.py``,
``tests/scripts/test_cursor_snapshot.py`` — all already on main).

Rationale:

* It works for module files whose path contains hyphens (e.g.
  ``acli-integration.py``), which Python's import system cannot resolve as a
  regular module name.
* It avoids implicit ``sys.path`` requirements — no conftest-level path
  manipulation is needed for tests to find the modules under test.
* It keeps each test self-contained: the exact file under test is named at
  the call site, so a moved or renamed module surfaces a clear loader error
  rather than a confusing ``ImportError``.

Rewriting these tests to use idiomatic ``import`` would diverge from the
established convention across the test tree; new tests in this directory
should follow the same loader pattern.
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
