# Synthetic migration-sweep fixture — app package init
#
# This package is part of the migration-sweep test fixture used by
# tests/implementation-plan/test-sweep-pair-emission.sh (task 8803).
#
# Purpose: provide a small synthetic codebase with ≥5 non-test, non-import
# call sites of `legacy_call(...)` so that migration-class-detect.sh
# classifies it as migration-class:sweep when run with the pinned
# fixture-config.conf (migration.call_site_threshold=3).
#
# Omitted-site convention: exactly one call site carries a sweep-marker comment
# to mark the site that a sweep simulation must catch. See users.py line 26.

from .legacy_helpers import legacy_call  # noqa: F401


def bootstrap() -> None:
    """Run bootstrap initialisation via the legacy entry point."""
    legacy_call("bootstrap")
