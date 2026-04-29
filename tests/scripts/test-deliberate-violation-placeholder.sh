#!/usr/bin/env bash
# DELIBERATE SECURITY VIOLATION FOR STORY ab65-49f6 (E2E test — do not merge)
# This file exists solely to trigger the security overlay in CI.
# It will be deleted when this story is closed.
# shellcheck disable=SC2034

# DELIBERATE_VIOLATION: hardcoded credential pattern (synthetic test value only)
DB_PASSWORD='hunter2-deliberate-test-violation-for-story-ab65-49f6-do-not-use'
API_ENDPOINT='http://internal-api.example.com/admin?password=deliberate-test-ab65-49f6'
SECRET_TOKEN='secret=sk-FAKE-NO-REAL-VALUE-FOR-E2E-TEST-ONLY-story-ab65-49f6-1234'
