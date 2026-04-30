#!/usr/bin/env bash
# DELIBERATE-TEST-VIOLATION: synthetic credential for CI security overlay verification
# Story: ab65-49f6 — CI security overlay real-PR verification
#
# REVIEW-DEFENSE: This file is intentionally placed in docs/ (not tests/) because
# ci-llm-review-runner.sh's security red-team reviewer applies a hard exclusion list
# that skips files matching tests/* and test_* patterns. A fixture in tests/fixtures/
# (e.g., the existing violation-credentials.sh) cannot produce security findings in CI —
# the red team will exclude it and return N/A with no blocking. This docs/ location is
# required so the security overlay can observe the credential pattern and exit non-zero.
#
# REVIEW-DEFENSE: This file is PR-only and is NEVER merged to main. The PR branch
# (test/security-overlay-v2-*) is closed after CI verification completes; deletion
# of this fixture is automatic when the branch is deleted. There is no risk of this
# file persisting in the main branch history.
#
# This file intentionally contains a synthetic hardcoded credential pattern to
# trigger the ci-llm-review-runner.sh security overlay in CI. It is NOT a real
# credential.
#
# The string below matches the OpenAI sk-... key pattern that the security
# red-team reviewer flags for hardcoded credential findings.

FAKE_OPENAI_KEY="sk-FAKE-TEST-ONLY-deliberate-violation-for-overlay-verification-1234567890abcdef"

echo "This file exists only to trigger the CI security overlay. Do not merge."
