"""Tests for visual_eval_api.py (Story 3: Live VLM Evaluation Module)."""

import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(
    0, str(Path(__file__).parent.parent.parent / "plugins" / "dso" / "scripts")
)

from visual_eval_api import evaluate_screenshot, _load_params, _build_user_prompt


@pytest.fixture
def sample_screenshot(tmp_path):
    img = tmp_path / "test.png"
    img.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 100)
    return img


@pytest.fixture
def sample_params(tmp_path):
    params = tmp_path / "params.yaml"
    params.write_text(
        "model_id: claude-sonnet-4-6\n"
        "temperature: 0\n"
        "thinking_budget: 8000\n"
        "max_tokens: 16000\n"
    )
    return params


@pytest.fixture
def valid_response():
    return {
        "scores": {
            "whitespace_balance": 4,
            "element_density": 3,
            "visual_hierarchy_legibility": 4,
            "alignment_grid_adherence": 4,
            "intent_match": 4,
        },
        "findings": [],
        "attribution_class": "implementation_drift",
        "attribution_confidence": "high",
    }


class TestEvaluateScreenshot:
    def test_missing_screenshot_returns_inapplicable(self, tmp_path, sample_params):
        result = evaluate_screenshot(
            tmp_path / "nonexistent.png",
            params_path=sample_params,
        )
        assert result["visual_eval_inapplicable"] == "screenshot_missing"

    def test_missing_anthropic_returns_inapplicable(
        self, sample_screenshot, sample_params
    ):
        with patch.dict(sys.modules, {"anthropic": None}):
            import visual_eval_api

            original = visual_eval_api.anthropic
            visual_eval_api.anthropic = None
            try:
                result = visual_eval_api.evaluate_screenshot(
                    sample_screenshot, params_path=sample_params
                )
                assert result["visual_eval_inapplicable"] == "anthropic_sdk_missing"
            finally:
                visual_eval_api.anthropic = original

    @patch("visual_eval_api.anthropic")
    def test_successful_evaluation(
        self, mock_anthropic, sample_screenshot, sample_params, valid_response
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client

        mock_block = MagicMock()
        mock_block.text = json.dumps(valid_response)
        mock_response = MagicMock()
        mock_response.content = [mock_block]
        mock_client.messages.create.return_value = mock_response

        result = evaluate_screenshot(
            sample_screenshot, params_path=sample_params, schema_path="/nonexistent"
        )

        assert result["scores"]["whitespace_balance"] == 4
        assert result["attribution_class"] == "implementation_drift"
        mock_client.messages.create.assert_called_once()

    @patch("visual_eval_api.anthropic")
    def test_api_call_params(
        self, mock_anthropic, sample_screenshot, sample_params, valid_response
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client

        mock_block = MagicMock()
        mock_block.text = json.dumps(valid_response)
        mock_response = MagicMock()
        mock_response.content = [mock_block]
        mock_client.messages.create.return_value = mock_response

        evaluate_screenshot(
            sample_screenshot, params_path=sample_params, schema_path="/nonexistent"
        )

        call_kwargs = mock_client.messages.create.call_args[1]
        assert call_kwargs["model"] == "claude-sonnet-4-6"
        assert call_kwargs["max_tokens"] == 16000
        assert call_kwargs["temperature"] == 0
        assert call_kwargs["thinking"]["budget_tokens"] == 8000
        # Verify image block is present
        user_msg = call_kwargs["messages"][0]
        assert user_msg["role"] == "user"
        image_block = user_msg["content"][0]
        assert image_block["type"] == "image"
        assert image_block["source"]["media_type"] == "image/png"

    @patch("visual_eval_api.anthropic")
    def test_api_timeout_graceful_degradation(
        self, mock_anthropic, sample_screenshot, sample_params
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_anthropic.APITimeoutError = type("APITimeoutError", (Exception,), {})
        mock_anthropic.APIError = type("APIError", (Exception,), {})
        mock_client.messages.create.side_effect = mock_anthropic.APITimeoutError(
            "timeout"
        )

        result = evaluate_screenshot(sample_screenshot, params_path=sample_params)
        assert result["visual_eval_inapplicable"] == "api_timeout"

    @patch("visual_eval_api.anthropic")
    def test_api_error_graceful_degradation(
        self, mock_anthropic, sample_screenshot, sample_params
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_anthropic.APITimeoutError = type("APITimeoutError", (Exception,), {})
        mock_anthropic.APIError = type("APIError", (Exception,), {})
        mock_client.messages.create.side_effect = mock_anthropic.APIError(
            "server error"
        )

        result = evaluate_screenshot(sample_screenshot, params_path=sample_params)
        assert result["visual_eval_inapplicable"] == "api_error"

    @patch("visual_eval_api.anthropic")
    def test_invalid_json_response(
        self, mock_anthropic, sample_screenshot, sample_params
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_anthropic.APITimeoutError = type("APITimeoutError", (Exception,), {})
        mock_anthropic.APIError = type("APIError", (Exception,), {})

        mock_block = MagicMock()
        mock_block.text = "This is not JSON at all"
        mock_response = MagicMock()
        mock_response.content = [mock_block]
        mock_client.messages.create.return_value = mock_response

        result = evaluate_screenshot(sample_screenshot, params_path=sample_params)
        assert result["visual_eval_inapplicable"] == "invalid_json"

    @patch("visual_eval_api.anthropic")
    def test_json_in_code_block_extracted(
        self, mock_anthropic, sample_screenshot, sample_params, valid_response
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_anthropic.APITimeoutError = type("APITimeoutError", (Exception,), {})
        mock_anthropic.APIError = type("APIError", (Exception,), {})

        mock_block = MagicMock()
        mock_block.text = f"```json\n{json.dumps(valid_response)}\n```"
        mock_response = MagicMock()
        mock_response.content = [mock_block]
        mock_client.messages.create.return_value = mock_response

        result = evaluate_screenshot(
            sample_screenshot, params_path=sample_params, schema_path="/nonexistent"
        )
        assert result["scores"]["whitespace_balance"] == 4


class TestLoadParams:
    def test_missing_file_returns_defaults(self):
        params = _load_params("/nonexistent/params.yaml")
        assert params["model_id"] == "claude-sonnet-4-6"
        assert params["thinking_budget"] == 8000

    def test_reads_yaml_file(self, tmp_path):
        f = tmp_path / "p.yaml"
        f.write_text("model_id: claude-opus-4-7\ntemperature: 0\n")
        params = _load_params(f)
        assert params["model_id"] == "claude-opus-4-7"


class TestSchemaValidation:
    @patch("visual_eval_api.anthropic")
    def test_schema_validation_rejects_invalid(
        self, mock_anthropic, sample_screenshot, sample_params
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_anthropic.APITimeoutError = type("APITimeoutError", (Exception,), {})
        mock_anthropic.APIError = type("APIError", (Exception,), {})

        invalid_response = {
            "scores": {
                "whitespace_balance": 4,
                "element_density": 3,
                "visual_hierarchy_legibility": 4,
                "alignment_grid_adherence": 4,
                "intent_match": "not_an_integer",
            },
            "findings": [],
            "attribution_class": "implementation_drift",
            "attribution_confidence": "high",
        }
        mock_block = MagicMock()
        mock_block.text = json.dumps(invalid_response)
        mock_response = MagicMock()
        mock_response.content = [mock_block]
        mock_client.messages.create.return_value = mock_response

        schema_path = (
            Path(__file__).parent.parent.parent
            / "plugins"
            / "dso"
            / "docs"
            / "visual-evaluator-schema.json"
        )
        if not schema_path.exists():
            pytest.skip("Schema file not found")

        result = evaluate_screenshot(
            sample_screenshot, params_path=sample_params, schema_path=schema_path
        )
        assert result["visual_eval_inapplicable"] == "schema_validation_failed"

    @patch("visual_eval_api.anthropic")
    def test_schema_validation_passes_valid(
        self, mock_anthropic, sample_screenshot, sample_params, valid_response
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_anthropic.APITimeoutError = type("APITimeoutError", (Exception,), {})
        mock_anthropic.APIError = type("APIError", (Exception,), {})

        mock_block = MagicMock()
        mock_block.text = json.dumps(valid_response)
        mock_response = MagicMock()
        mock_response.content = [mock_block]
        mock_client.messages.create.return_value = mock_response

        schema_path = (
            Path(__file__).parent.parent.parent
            / "plugins"
            / "dso"
            / "docs"
            / "visual-evaluator-schema.json"
        )
        if not schema_path.exists():
            pytest.skip("Schema file not found")

        result = evaluate_screenshot(
            sample_screenshot, params_path=sample_params, schema_path=schema_path
        )
        assert "visual_eval_inapplicable" not in result
        assert result["scores"]["whitespace_balance"] == 4

    @patch("visual_eval_api.anthropic")
    def test_api_timeout_configured(
        self, mock_anthropic, sample_screenshot, sample_params, valid_response
    ):
        mock_client = MagicMock()
        mock_anthropic.Anthropic.return_value = mock_client
        mock_anthropic.APITimeoutError = type("APITimeoutError", (Exception,), {})
        mock_anthropic.APIError = type("APIError", (Exception,), {})

        mock_block = MagicMock()
        mock_block.text = json.dumps(valid_response)
        mock_response = MagicMock()
        mock_response.content = [mock_block]
        mock_client.messages.create.return_value = mock_response

        evaluate_screenshot(
            sample_screenshot, params_path=sample_params, schema_path="/nonexistent"
        )
        mock_anthropic.Anthropic.assert_called_once()
        call_kwargs = mock_anthropic.Anthropic.call_args[1]
        assert "timeout" in call_kwargs
        assert call_kwargs["timeout"] == 60.0


class TestBuildUserPrompt:
    def test_without_manifest(self):
        prompt = _build_user_prompt(None)
        assert "standalone visual quality" in prompt

    def test_with_manifest(self):
        manifest = {"layout": "grid", "colors": ["#fff"]}
        prompt = _build_user_prompt(manifest)
        assert "Design manifest" in prompt
        assert "grid" in prompt
