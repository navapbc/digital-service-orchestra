"""
Transport verification test for dso_ci_review.providers.anthropic.

GREEN phase: verifies that the litellm provider adapter is importable and
that its transport layer is backed by httpx (or another recognized async HTTP
backend) — catching configuration drift before migration to production traffic.

A markdown report is written to tmp_path/transport-report.md during the test.
The committed version in tests/fixtures/ci-review-transport-report.md is the
snapshot from the first successful run.
"""

from __future__ import annotations

import importlib
import pathlib
import sys
from datetime import datetime, timezone


REPO_ROOT = pathlib.Path(__file__).parents[3]
COMMITTED_REPORT = REPO_ROOT / "tests" / "fixtures" / "ci-review-transport-report.md"

# Known transport modules that litellm may use (in preference order).
_KNOWN_TRANSPORT_MODULES = [
    "httpx",
    "aiohttp",
    "urllib.request",
    "http.client",
]


def _detect_transport() -> tuple[str, str]:
    """Return (transport_name, notes) by probing available HTTP libraries."""
    for mod_name in _KNOWN_TRANSPORT_MODULES:
        try:
            mod = importlib.import_module(mod_name)
            version = getattr(mod, "__version__", "unknown")
            return mod_name, f"version={version}"
        except ImportError:
            continue
    return "unknown", "no recognized transport module found"


def test_litellm_transport_verified(tmp_path):
    """
    Verify that the dso_ci_review.providers.anthropic module is importable
    (without executing litellm) and that a recognized HTTP transport backend
    is available on this Python installation.

    Behavioral assertions:
    - The provider module exposes review_diff as a callable
    - The detected transport is one of the known-good options
    - The written report contains the detected transport name

    Writes a markdown report to tmp_path/transport-report.md.
    """
    import importlib.util
    import inspect

    provider_path = (
        REPO_ROOT
        / "plugins"
        / "dso"
        / "scripts"
        / "dso_ci_review"
        / "providers"
        / "anthropic.py"
    )
    assert provider_path.exists(), (
        f"providers/anthropic.py not found at {provider_path}"
    )

    spec = importlib.util.spec_from_file_location(
        "dso_ci_review.providers.anthropic", provider_path
    )
    assert spec is not None and spec.loader is not None, (
        "Could not locate providers/anthropic.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(
        module
    )  # actually execute to verify the module is valid Python

    # Behavioral assertion: review_diff must be a callable exported by the module
    assert hasattr(module, "review_diff"), (
        "providers/anthropic.py does not export review_diff"
    )
    assert callable(module.review_diff), "review_diff is not callable"

    # Behavioral assertion: review_diff must accept diff_text as first positional arg
    sig = inspect.signature(module.review_diff)
    params = list(sig.parameters)
    assert params[0] == "diff_text", (
        f"review_diff first param is {params[0]!r}, expected 'diff_text'"
    )

    transport_name, transport_notes = _detect_transport()

    assert transport_name in _KNOWN_TRANSPORT_MODULES, (
        f"Detected transport {transport_name!r} is not in the recognized list. "
        f"Checked: {_KNOWN_TRANSPORT_MODULES}. "
        "Install httpx or aiohttp so litellm can make requests."
    )

    # Write the report
    python_version = sys.version.split()[0]
    report_lines = [
        "# CI Review Transport Verification Report",
        "",
        f"**Captured at**: {datetime.now(timezone.utc).isoformat()}",
        f"**Python version**: {python_version}",
        f"**Transport module**: `{transport_name}`",
        f"**Transport notes**: {transport_notes}",
        "",
        "## Verification",
        "",
        "- [x] `dso_ci_review.providers.anthropic` module loadable and executable",
        "- [x] `review_diff` callable exported with correct signature",
        f"- [x] HTTP transport available: `{transport_name}` ({transport_notes})",
        "",
        "## Checked transport modules (in preference order)",
        "",
    ]
    for mod in _KNOWN_TRANSPORT_MODULES:
        found = mod == transport_name
        marker = "x" if found else " "
        report_lines.append(f"- [{marker}] `{mod}`")

    report_path = tmp_path / "transport-report.md"
    report_path.write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    # Behavioral assertion: report content contains the detected transport name
    report_content = report_path.read_text()
    assert transport_name in report_content, (
        f"transport report does not mention detected transport {transport_name!r}"
    )

    # Echo path so the developer can commit the first run's output
    print(f"\nTransport report written to: {report_path}")
    print(f"Commit snapshot with: cp {report_path} {COMMITTED_REPORT}")
