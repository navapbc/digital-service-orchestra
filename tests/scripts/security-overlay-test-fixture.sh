#!/usr/bin/env bash
# DELIBERATE-TEST-VIOLATION: synthetic credential for CI security overlay verification
# Story: ab65-49f6 — CI security overlay real-PR verification
#
# This file intentionally contains a synthetic hardcoded credential pattern to
# trigger the ci-llm-review-runner.sh security overlay in CI. It is NOT a real
# credential. This file must be deleted after the PR check is complete.
#
# The string below matches the OpenAI sk-... key pattern that the security
# red-team reviewer flags for hardcoded credential findings.

FAKE_OPENAI_KEY="sk-FAKE-TEST-ONLY-deliberate-violation-for-overlay-verification-1234567890abcdef"

echo "This file exists only to trigger the CI security overlay. Do not merge."
