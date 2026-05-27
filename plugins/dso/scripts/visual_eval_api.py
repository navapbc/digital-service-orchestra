"""Live VLM evaluation module for sprint integration.

Separate from label_visual_corpus.py (calibration labeling != sprint evaluation).
Provides single-shot screenshot evaluation via the visual-evaluator agent prompt.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
from typing import Any

import yaml

try:
    import jsonschema
except ImportError:
    jsonschema = None  # type: ignore[assignment]

try:
    import anthropic
except ImportError:
    anthropic = None  # type: ignore[assignment]


def _load_params(params_path: str | Path) -> dict[str, Any]:
    path = Path(params_path)
    if not path.exists():
        return {
            "model_id": "claude-sonnet-4-6",
            "temperature": 0,
            "thinking_budget": 8000,
            "max_tokens": 16000,
        }
    with open(path) as f:
        return yaml.safe_load(f)


def _load_schema(schema_path: str | Path | None = None) -> dict[str, Any] | None:
    if schema_path is None:
        _plugin_root = Path(
            os.environ.get("CLAUDE_PLUGIN_ROOT", Path(__file__).parent.parent)
        )
        candidates = [
            _plugin_root / "docs" / "visual-evaluator-schema.json",
            Path(__file__).parent.parent / "docs" / "visual-evaluator-schema.json",
        ]
        for c in candidates:
            if c.exists():
                schema_path = c
                break
    if schema_path is None:
        return None
    path = Path(schema_path)
    if not path.exists():
        return None
    with open(path) as f:
        return json.load(f)


def _load_agent_prompt(agent_path: str | Path | None = None) -> str:
    if agent_path is None:
        _plugin_root = Path(
            os.environ.get("CLAUDE_PLUGIN_ROOT", Path(__file__).parent.parent)
        )
        candidates = [
            _plugin_root / "agents" / "visual-evaluator.md",
            Path(__file__).parent.parent / "agents" / "visual-evaluator.md",
        ]
        for c in candidates:
            if c.exists():
                agent_path = c
                break
    if agent_path is None:
        return "Evaluate this screenshot and return JSON with scores, findings, attribution_class, and attribution_confidence."
    path = Path(agent_path)
    if not path.exists():
        return "Evaluate this screenshot and return JSON with scores, findings, attribution_class, and attribution_confidence."
    content = path.read_text()
    # Strip YAML frontmatter
    if content.startswith("---"):
        end = content.find("---", 3)
        if end != -1:
            content = content[end + 3 :].strip()
    return content


def _encode_image(screenshot_path: str | Path) -> str:
    path = Path(screenshot_path)
    with open(path, "rb") as f:
        return base64.standard_b64encode(f.read()).decode("ascii")


def evaluate_screenshot(
    screenshot_path: str | Path,
    design_manifest: dict[str, Any] | None = None,
    params_path: str | Path | None = None,
    schema_path: str | Path | None = None,
    agent_path: str | Path | None = None,
) -> dict[str, Any]:
    """Single-shot VLM evaluation of one screenshot.

    Returns parsed JSON conforming to visual-evaluator-schema.json.
    On failure, returns {"visual_eval_inapplicable": "<reason>", "error": str}.
    """
    path = Path(screenshot_path)
    if not path.exists():
        return {
            "visual_eval_inapplicable": "screenshot_missing",
            "error": f"Screenshot not found: {screenshot_path}",
        }

    if anthropic is None:
        return {
            "visual_eval_inapplicable": "anthropic_sdk_missing",
            "error": "anthropic package not installed",
        }

    if params_path is None:
        _plugin_root = Path(
            os.environ.get("CLAUDE_PLUGIN_ROOT", Path(__file__).parent.parent)
        )
        params_path = _plugin_root / "config" / "visual-evaluator-params.yaml"
    params = _load_params(params_path)
    schema = _load_schema(schema_path)
    agent_prompt = _load_agent_prompt(agent_path)

    image_data = _encode_image(path)
    media_type = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"

    user_content: list[dict[str, Any]] = [
        {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media_type,
                "data": image_data,
            },
        },
        {
            "type": "text",
            "text": _build_user_prompt(design_manifest),
        },
    ]

    try:
        client = anthropic.Anthropic(timeout=params.get("api_timeout", 60.0))
        response = client.messages.create(
            model=params.get("model_id", "claude-sonnet-4-6"),
            max_tokens=params.get("max_tokens", 16000),
            temperature=params.get("temperature", 0),
            thinking={
                "type": "enabled",
                "budget_tokens": params.get("thinking_budget", 8000),
            },
            system=agent_prompt,
            messages=[{"role": "user", "content": user_content}],
        )
    except anthropic.APITimeoutError as e:
        return {
            "visual_eval_inapplicable": "api_timeout",
            "error": str(e),
        }
    except anthropic.APIError as e:
        return {
            "visual_eval_inapplicable": "api_error",
            "error": str(e),
        }

    # Extract JSON from response
    result_text = ""
    for block in response.content:
        if hasattr(block, "text"):
            result_text += block.text

    try:
        result = json.loads(result_text)
    except json.JSONDecodeError:
        # Try extracting JSON from markdown code block
        import re

        match = re.search(r"```(?:json)?\s*\n?(.*?)\n?```", result_text, re.DOTALL)
        if match:
            try:
                result = json.loads(match.group(1))
            except json.JSONDecodeError:
                return {
                    "visual_eval_inapplicable": "invalid_json",
                    "error": f"Could not parse response as JSON: {result_text[:200]}",
                }
        else:
            return {
                "visual_eval_inapplicable": "invalid_json",
                "error": f"Could not parse response as JSON: {result_text[:200]}",
            }

    # Validate against schema
    if schema and jsonschema:
        try:
            jsonschema.validate(instance=result, schema=schema)
        except jsonschema.ValidationError as e:
            return {
                "visual_eval_inapplicable": "schema_validation_failed",
                "error": f"Schema validation failed: {e.message}",
            }

    return result


def _build_user_prompt(design_manifest: dict[str, Any] | None) -> str:
    parts = ["Evaluate this screenshot."]
    if design_manifest:
        parts.append(
            f"\n\nDesign manifest:\n```json\n{json.dumps(design_manifest, indent=2)}\n```"
        )
    else:
        parts.append(
            "\n\nNo design manifest provided. Evaluate standalone visual quality."
        )
    parts.append("\n\nReturn ONLY the JSON evaluation object, no other text.")
    return "".join(parts)
