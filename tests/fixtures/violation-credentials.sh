#!/usr/bin/env bash
# SECURITY VIOLATION: hardcoded credentials for ab65-49f6 E2E test
# This file intentionally contains security anti-patterns to trigger the
# security overlay in dso_ci_review.runner (ci-llm-review-runner.sh is a shim in S3+)
AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
GITHUB_TOKEN="ghp_fake1234567890abcdefghijklmnopqrstuvwxyz"
DB_PASSWORD="super_secret_prod_password_123"
