"""RED tests for dso_ci_review.providers.config (not yet implemented).

All tests in this module are expected to FAIL with ModuleNotFoundError or
ImportError until T4 implements providers/config.py.

RED marker: tests/skills/dso_ci_review/test_providers_config.py [test_env_var_wins_over_config]
"""

import pathlib

import pytest

# This import will raise ModuleNotFoundError / ImportError until config.py exists
from dso_ci_review.providers.config import (
    AuthError,
    ConfigError,
    get_provider,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
DSO_CONFIG = REPO_ROOT / ".claude" / "dso-config.conf"


class TestGetProviderEnvVarPrecedence:
    """Verify that CI_REVIEW_PROVIDER env var wins over config file."""

    def test_env_var_wins_over_config(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
    ) -> None:
        """Given: CI_REVIEW_PROVIDER=anthropic in env AND ci_review.provider=openai in config
        When: get_provider() is called
        Then: returns an AnthropicProvider instance (env wins over config)
        """
        # Arrange — write a config file that says openai
        config_file = tmp_path / "dso-config.conf"
        config_file.write_text("ci_review.provider=openai\n")

        monkeypatch.setenv("CI_REVIEW_PROVIDER", "anthropic")
        monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key-abc123")
        monkeypatch.setenv("DSO_CONFIG_FILE", str(config_file))

        # Act
        provider = get_provider()

        # Assert — env var beats config file
        assert provider.__class__.__name__ == "AnthropicProvider", (
            f"Expected AnthropicProvider, got {type(provider).__name__}"
        )


class TestGetProviderMissingConfiguration:
    """Verify fail-loud behaviour when no provider is configured."""

    def test_missing_provider_config_raises_config_error(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
    ) -> None:
        """Given: no CI_REVIEW_PROVIDER env, no config key
        When: get_provider() is called
        Then: raises ConfigError with message containing 'provider' or 'config'
        """
        # Arrange — empty config file, no env var
        config_file = tmp_path / "dso-config.conf"
        config_file.write_text("")

        monkeypatch.delenv("CI_REVIEW_PROVIDER", raising=False)
        monkeypatch.setenv("DSO_CONFIG_FILE", str(config_file))

        # Act + Assert
        with pytest.raises(ConfigError) as exc_info:
            get_provider()

        msg = str(exc_info.value).lower()
        assert "provider" in msg or "config" in msg, (
            f"Expected error message to mention 'provider' or 'config', got: {exc_info.value!r}"
        )


class TestGetProviderUnknownProvider:
    """Verify fail-loud behaviour for unsupported provider names."""

    def test_unknown_provider_raises_config_error(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
    ) -> None:
        """Given: CI_REVIEW_PROVIDER=gemini (not implemented)
        When: get_provider() is called with gemini as provider via env var
        Then: raises ConfigError
        """
        config_file = tmp_path / "dso-config.conf"
        config_file.write_text("")
        monkeypatch.setenv("CI_REVIEW_PROVIDER", "gemini")
        monkeypatch.setenv("DSO_CONFIG_FILE", str(config_file))
        with pytest.raises(ConfigError):
            get_provider()


class TestGetProviderMissingApiKey:
    """Verify fail-loud behaviour when the API key is absent."""

    def test_missing_api_key_raises_auth_error(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
    ) -> None:
        """Given: CI_REVIEW_PROVIDER=anthropic, ANTHROPIC_API_KEY absent
        When: get_provider() is called
        Then: raises AuthError (not ConfigError — provider is known, key is missing)
        """
        config_file = tmp_path / "dso-config.conf"
        config_file.write_text("")
        monkeypatch.setenv("CI_REVIEW_PROVIDER", "anthropic")
        monkeypatch.setenv("DSO_CONFIG_FILE", str(config_file))
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

        with pytest.raises(AuthError):
            get_provider()


class TestGetProviderEmptyEnvVarFallback:
    """Verify that an empty env var is treated as absent and config is used."""

    def test_empty_env_var_falls_back_to_config(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
    ) -> None:
        """Given: CI_REVIEW_PROVIDER= (empty string), ci_review.provider=openai in config file
        When: get_provider() is called
        Then: returns OpenAIProvider (empty string env treated as absent, falls back to config)
        """
        # Arrange — config file says openai; env var is empty string (not absent)
        config_file = tmp_path / "dso-config.conf"
        config_file.write_text("ci_review.provider=openai\n")

        monkeypatch.setenv("CI_REVIEW_PROVIDER", "")
        monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key-xyz")
        monkeypatch.setenv("DSO_CONFIG_FILE", str(config_file))

        # Act
        provider = get_provider()

        # Assert — empty env var falls back to config value (openai)
        assert provider.__class__.__name__ == "OpenAIProvider", (
            f"Expected OpenAIProvider (config fallback), got {type(provider).__name__}"
        )
