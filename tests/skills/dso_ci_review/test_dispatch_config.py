"""RED tests for parse_provider_chain and validate_provider_credentials (DD4).

These tests FAIL until the implementation task adds parse_provider_chain and
validate_provider_credentials to dso_ci_review.providers.config.

RED marker: tests/skills/dso_ci_review/test_dispatch_config.py [test_parse_provider_chain_valid]
"""

from __future__ import annotations

import pytest

# Both functions do not exist yet — importing them will raise ImportError
# (AttributeError at minimum) until the implementation task is complete.
from dso_ci_review.providers.config import (  # noqa: F401  (imported for side-effect check)
    ConfigError,
    parse_provider_chain,
    validate_provider_credentials,
)


class TestParseProviderChainValid:
    """parse_provider_chain returns a correctly ordered list for valid input."""

    def test_parse_provider_chain_valid(self) -> None:
        """Given: "anthropic,openai"
        When: parse_provider_chain is called
        Then: returns ["anthropic", "openai"] in that order
        """
        result = parse_provider_chain("anthropic,openai")
        assert result == ["anthropic", "openai"], (
            f"Expected ['anthropic', 'openai'], got {result!r}"
        )

    def test_parse_provider_chain_single_entry(self) -> None:
        """Given: "anthropic"
        When: parse_provider_chain is called
        Then: returns ["anthropic"]
        """
        result = parse_provider_chain("anthropic")
        assert result == ["anthropic"], f"Expected ['anthropic'], got {result!r}"


class TestParseProviderChainUnknown:
    """parse_provider_chain raises ValueError for unknown provider names."""

    def test_unknown_provider_raises_value_error(self) -> None:
        """Given: "gemini" (not in the known provider set)
        When: parse_provider_chain is called
        Then: raises ValueError (unknown provider rejected at parse time)
        """
        with pytest.raises(ValueError):
            parse_provider_chain("gemini")

    def test_unknown_provider_in_chain_raises_value_error(self) -> None:
        """Given: "anthropic,gemini" (mixed valid and unknown)
        When: parse_provider_chain is called
        Then: raises ValueError — any unknown entry rejects the whole chain
        """
        with pytest.raises(ValueError):
            parse_provider_chain("anthropic,gemini")


class TestParseProviderChainCaseSensitive:
    """parse_provider_chain is case-sensitive; uppercase names are rejected."""

    def test_uppercase_anthropic_raises_value_error(self) -> None:
        """Given: "Anthropic" (capitalised)
        When: parse_provider_chain is called
        Then: raises ValueError — case-sensitive rejection
        """
        with pytest.raises(ValueError):
            parse_provider_chain("Anthropic")

    def test_allcaps_openai_raises_value_error(self) -> None:
        """Given: "OPENAI"
        When: parse_provider_chain is called
        Then: raises ValueError
        """
        with pytest.raises(ValueError):
            parse_provider_chain("OPENAI")


class TestParseProviderChainWhitespaceTrimming:
    """parse_provider_chain strips surrounding whitespace from each token."""

    def test_whitespace_trimmed_returns_clean_list(self) -> None:
        """Given: " anthropic , openai " (spaces around names)
        When: parse_provider_chain is called
        Then: returns ["anthropic", "openai"] — whitespace trimmed, not rejected
        """
        result = parse_provider_chain(" anthropic , openai ")
        assert result == ["anthropic", "openai"], (
            f"Expected ['anthropic', 'openai'] after trimming, got {result!r}"
        )


class TestValidateProviderCredentialsMissingKey:
    """validate_provider_credentials raises ConfigError when a required key is absent."""

    def test_missing_anthropic_api_key_raises_config_error(self) -> None:
        """Given: providers=["anthropic"], environ={} (ANTHROPIC_API_KEY absent)
        When: validate_provider_credentials is called
        Then: raises ConfigError mentioning the missing key
        """
        with pytest.raises(ConfigError) as exc_info:
            validate_provider_credentials(["anthropic"], environ={})

        msg = str(exc_info.value)
        assert "ANTHROPIC_API_KEY" in msg, (
            f"Expected ConfigError to mention 'ANTHROPIC_API_KEY', got: {msg!r}"
        )

    def test_missing_openai_api_key_raises_config_error(self) -> None:
        """Given: providers=["openai"], environ={} (OPENAI_API_KEY absent)
        When: validate_provider_credentials is called
        Then: raises ConfigError mentioning the missing key
        """
        with pytest.raises(ConfigError) as exc_info:
            validate_provider_credentials(["openai"], environ={})

        msg = str(exc_info.value)
        assert "OPENAI_API_KEY" in msg, (
            f"Expected ConfigError to mention 'OPENAI_API_KEY', got: {msg!r}"
        )

    def test_all_keys_present_does_not_raise(self) -> None:
        """Given: providers=["anthropic", "openai"], all required keys present
        When: validate_provider_credentials is called
        Then: returns None without raising
        """
        environ = {
            "ANTHROPIC_API_KEY": "test-anthropic-key",
            "OPENAI_API_KEY": "test-openai-key",
        }
        # Should not raise; validate_provider_credentials returns None on success
        validate_provider_credentials(["anthropic", "openai"], environ=environ)
