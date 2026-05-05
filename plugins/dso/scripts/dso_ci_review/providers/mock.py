"""Stub mock provider for dso_ci_review tests.

Full implementation deferred to S2 T2.
"""

from __future__ import annotations

from typing import Any


class MockProvider:
    """Stub mock provider — full implementation in S2 T2."""

    def review_diff(self, diff_text: str, **kwargs: Any) -> dict[str, Any]:
        raise NotImplementedError("MockProvider is a stub pending S2 T2 implementation")
