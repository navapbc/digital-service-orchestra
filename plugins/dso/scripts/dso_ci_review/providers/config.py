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


_KNOWN_PROVIDERS: frozenset[str] = frozenset(_PROVIDER_MAP)

_PROVIDER_KEY_MAP: dict[str, str] = {
    name: api_key_var for name, (_, _, api_key_var) in _PROVIDER_MAP.items()
}


def parse_provider_chain(value: str) -> list[str]:
    """Parse a comma-separated provider chain string into a validated list.

    Args:
        value: Comma-separated provider names, e.g. ``"anthropic,openai"``.
               Whitespace around each name is stripped before validation.

    Returns:
        Ordered list of provider name strings.

    Raises:
        ValueError: If *value* is empty, or any name is not in the known
            provider set.  Validation is case-sensitive.
    """
    if not value or not value.strip():
        raise ValueError("Provider chain value must not be empty.")

    parts = [token.strip() for token in value.split(",")]
    for part in parts:
        if part not in _KNOWN_PROVIDERS:
            known = ", ".join(sorted(_KNOWN_PROVIDERS))
            raise ValueError(f"Unknown provider {part!r}. Known providers: {known}")
    return parts


def validate_provider_credentials(
    providers: list[str], environ: dict[str, str]
) -> None:
    """Verify that required API key env vars are present for each provider.

    Args:
        providers: List of provider names (as returned by
            :func:`parse_provider_chain`).
        environ: Mapping of environment variable names to values (typically
            ``os.environ`` or a test-supplied dict).

    Raises:
        ConfigError: If any provider's required API key is absent from
            *environ*.  The error message includes the missing key name.
    """
    for name in providers:
        key = _PROVIDER_KEY_MAP.get(name)
        if key is None:
            raise ConfigError(f"Unknown provider {name!r} in credential check.")
        if not environ.get(key):
            raise ConfigError(
                f"Provider {name!r} requires {key} env var, but it is not set."
            )


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
