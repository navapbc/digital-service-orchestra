"""Shared fixtures for dso_ci_review tests."""

import json
import pathlib

import pytest

REPO_ROOT = pathlib.Path(__file__).parents[3]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus"


@pytest.fixture()
def fixture_diff_path():
    """Return path to the fixture diff file."""
    return FIXTURE_DIR / "fixture-diff.txt"


@pytest.fixture()
def canned_findings_dict():
    """Return a minimal canned LLM response dict shaped like litellm.completion output."""
    return {
        "choices": [
            {
                "message": {
                    "content": json.dumps(
                        {
                            "findings": [
                                {
                                    "severity": "minor",
                                    "description": "Example finding from fixture",
                                    "cited_lines": ["plugins/dso/scripts/example.py:1"],
                                }
                            ]
                        }
                    )
                }
            }
        ]
    }
