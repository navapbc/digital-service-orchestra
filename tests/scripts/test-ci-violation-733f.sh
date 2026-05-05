#!/usr/bin/env bash
# DELIBERATE CI ENFORCEMENT TEST — this branch will be deleted after verification
# Story 733f-938c-e6d9-464d (epic 1083-fb3d)
# DO NOT MERGE — intentionally contains fake/example credentials for CI testing
# These are NOT real secrets and serve only to trigger the CI security overlay.

# Fake credential patterns (example values from public documentation):
export FAKE_GITHUB_TOKEN="ghp_FAKETEST1234567890123456789012345678"
export FAKE_AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export FAKE_AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
echo "CI enforcement test script — all values above are fake/example credentials"
