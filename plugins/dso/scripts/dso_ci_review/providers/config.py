"""Provider configuration and resolution for dso_ci_review.

Resolves the active LLM provider from environment variables or a config file,
and raises fail-loud errors to distinguish configuration problems from auth
problems.
"""

from __future__ import annotations

import os
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from dso_ci_review.providers.base import Provider


class ConfigError(Exception):
    """Raised when provider configuration is missing or invalid."""


class AuthError(Exception):
    """Raised when a known provider's API key env var is absent."""


_PROVIDER_MAP = {
    "anthropic": (
        "dso_ci_review.providers.anthropic",
        "AnthropicProvider",
        "ANTHROPIC_API_KEY",
    ),
    "openai": (
        "dso_ci_review.providers.openai",
        "OpenAIProvider",
        "OPENAI_API_KEY",
    ),
}


def get_provider(
    name: str | None = None,
    *,
    config_path: os.PathLike | None = None,
) -> "Provider":
    """Return a provider instance based on configuration.

    Resolution order:
    1. *name* argument (if provided and non-empty)
    2. ``CI_REVIEW_PROVIDER`` env var (non-empty after strip)
    3. ``DSO_CONFIG_FILE`` env var pointing to a config file, or *config_path* arg

    Args:
        name: Explicit provider name (overrides env and config).
        config_path: Path to a dso-config.conf-style file.  Checked after
            ``DSO_CONFIG_FILE`` env var when both are absent.

    Returns:
        An instantiated provider satisfying the :class:`Provider` Protocol.

    Raises:
        ConfigError: Provider name absent (nothing configured) or unknown.
        AuthError: Known provider requested but its API key env var is unset.
    """
    import importlib

    # --- Step 1: explicit argument ---
    provider_name: str | None = name if name else None

    # --- Step 2: CI_REVIEW_PROVIDER env var ---
    if not provider_name:
        env_val = os.environ.get("CI_REVIEW_PROVIDER", "")
        if env_val.strip():
            provider_name = env_val.strip()

    # --- Step 3: config file fallback ---
    if not provider_name:
        config_file = config_path or os.environ.get("DSO_CONFIG_FILE")
        if config_file and os.path.isfile(str(config_file)):
            with open(str(config_file), encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("ci_review.provider="):
                        provider_name = line[len("ci_review.provider=") :].strip()
                        break

    if not provider_name:
        raise ConfigError(
            "No provider configured. Set CI_REVIEW_PROVIDER env var or "
            "ci_review.provider in dso-config.conf."
        )

    if provider_name not in _PROVIDER_MAP:
        known = ", ".join(sorted(_PROVIDER_MAP))
        raise ConfigError(
            f"Unknown provider {provider_name!r}. Known providers: {known}"
        )

    module_name, class_name, api_key_var = _PROVIDER_MAP[provider_name]

    if not os.environ.get(api_key_var):
        raise AuthError(
            f"Provider {provider_name!r} requires {api_key_var} env var, "
            "but it is not set."
        )

    module = importlib.import_module(module_name)
    cls = getattr(module, class_name)
    return cls()
