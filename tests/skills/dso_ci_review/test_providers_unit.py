"""Unit tests for provider interface structural compliance.

DD1 (pre-implementation): RED tests for provider interface structural compliance.
DD3 (pre-implementation): RED test confirming MockProvider satisfies Provider Protocol.

Testing mode: RED — these tests define the interface contract before full implementation.

Import strategy: modules are loaded via importlib from the plugin scripts directory
to avoid a naming collision between this test package (tests/skills/dso_ci_review/)
and the real plugin package (plugins/dso/scripts/dso_ci_review/).
"""

from __future__ import annotations

import importlib.util
import inspect
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = _REPO_ROOT / "plugins" / "dso" / "scripts"


def _load_provider_module(relative_path: str) -> object:
    """Load a provider module from the plugin scripts directory by relative path.

    Uses importlib.util to bypass the test-package/plugin-package name collision.
    The module is registered in sys.modules so Protocol isinstance checks work
    (typing.Protocol requires the same class object for structural matching).
    """
    abs_path = _SCRIPTS_DIR / relative_path
    # Derive a unique module name that avoids shadowing the test package.
    module_name = "dso_ci_review_plugin." + relative_path.replace(
        "/", "."
    ).removesuffix(".py")

    if module_name in sys.modules:
        return sys.modules[module_name]

    spec = importlib.util.spec_from_file_location(module_name, abs_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load module from {abs_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def test_provider_protocol_exists() -> None:
    """
    Given: the dso_ci_review.providers.base module
    When: we load the Provider Protocol and inspect its interface
    Then: Provider is a class with review_diff in its protocol members,
          and runtime isinstance checks work (runtime_checkable)
    """
    base_mod = _load_provider_module("dso_ci_review/providers/base.py")
    Provider = base_mod.Provider  # type: ignore[attr-defined]

    assert inspect.isclass(Provider), "Provider must be a class"
    # Behavioral assertion: review_diff must be declared in the Protocol members
    assert "review_diff" in Provider.__protocol_attrs__, (  # type: ignore[attr-defined]
        "Provider Protocol must define review_diff as a structural requirement; "
        f"found members: {getattr(Provider, '__protocol_attrs__', set())}"
    )
    # Behavioral assertion: Provider is runtime_checkable (isinstance checks work)
    assert getattr(Provider, "_is_runtime_protocol", False), (
        "Provider must be decorated with @runtime_checkable to support isinstance checks"
    )


def test_anthropic_satisfies_protocol() -> None:
    """
    Given: dso_ci_review.providers.anthropic with AnthropicProvider class
    When: we inspect AnthropicProvider
    Then: it has a callable review_diff attribute with the expected signature
    """
    base_mod = _load_provider_module("dso_ci_review/providers/base.py")
    Provider = base_mod.Provider  # type: ignore[attr-defined]
    anthropic_mod = _load_provider_module("dso_ci_review/providers/anthropic.py")
    AnthropicProvider = anthropic_mod.AnthropicProvider  # type: ignore[attr-defined]

    assert inspect.isclass(AnthropicProvider), "AnthropicProvider must be a class"
    assert callable(getattr(AnthropicProvider, "review_diff", None)), (
        "AnthropicProvider must have a callable review_diff method"
    )

    # Verify signature: (self, diff_text: str, **kwargs) -> dict
    sig = inspect.signature(AnthropicProvider.review_diff)
    params = list(sig.parameters.keys())
    assert "diff_text" in params, (
        f"review_diff must accept diff_text parameter; got params: {params}"
    )
    assert any(
        p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()
    ), "review_diff must accept **kwargs"

    # Structural subtyping check via runtime_checkable Protocol
    instance = AnthropicProvider()
    assert isinstance(instance, Provider), (
        "AnthropicProvider instance must satisfy Provider Protocol"
    )


def test_mock_provider_stub_exists() -> None:
    """
    Given: dso_ci_review.providers.mock with MockProvider stub
    When: we inspect MockProvider
    Then: it exists, has review_diff with correct signature, and satisfies Provider Protocol
    """
    base_mod = _load_provider_module("dso_ci_review/providers/base.py")
    Provider = base_mod.Provider  # type: ignore[attr-defined]
    mock_mod = _load_provider_module("dso_ci_review/providers/mock.py")
    MockProvider = mock_mod.MockProvider  # type: ignore[attr-defined]

    assert inspect.isclass(MockProvider), "MockProvider must be a class"
    assert callable(getattr(MockProvider, "review_diff", None)), (
        "MockProvider must have a callable review_diff method"
    )

    # Verify signature matches Protocol
    sig = inspect.signature(MockProvider.review_diff)
    params = list(sig.parameters.keys())
    assert "diff_text" in params, (
        f"review_diff must accept diff_text parameter; got params: {params}"
    )
    assert any(
        p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()
    ), "review_diff must accept **kwargs"

    # Structural subtyping check
    instance = MockProvider()
    assert isinstance(instance, Provider), (
        "MockProvider instance must satisfy Provider Protocol"
    )


def test_openai_provider_review_diff() -> None:
    """
    Given: dso_ci_review.providers.openai with OpenAIProvider class (not yet implemented)
    When: we inspect OpenAIProvider.review_diff
    Then: AnthropicProvider.review_diff exists AND OpenAIProvider.review_diff exists

    """
    anthropic_mod = _load_provider_module("dso_ci_review/providers/anthropic.py")
    AnthropicProvider = anthropic_mod.AnthropicProvider  # type: ignore[attr-defined]

    # AnthropicProvider side — must pass
    assert callable(getattr(AnthropicProvider, "review_diff", None)), (
        "AnthropicProvider must have review_diff"
    )

    # OpenAIProvider side — RED: openai.py not yet created
    openai_mod = _load_provider_module("dso_ci_review/providers/openai.py")
    OpenAIProvider = openai_mod.OpenAIProvider  # type: ignore[attr-defined]  # noqa: F841

    assert callable(getattr(OpenAIProvider, "review_diff", None)), (
        "OpenAIProvider must have review_diff"
    )
