#!/usr/bin/env bash
# lockpick-workflow/scripts/format-and-lint.sh — Combined format-check + lint pre-commit hook
#
# Runs format check (ruff format) then lint (ruff check + mypy) in sequence,
# both via the pre-commit-wrapper.sh timeout/logging pattern.
#
# Usage (invoked by .pre-commit-config.yaml via pre-commit-wrapper.sh):
#   ./scripts/pre-commit-wrapper.sh format-and-lint 60 "lockpick-workflow/scripts/format-and-lint.sh"
#
# Debug commands:
#   cd app && PY_RUN_APPROACH=local make format-check
#   cd app && PY_RUN_APPROACH=local make lint
#
# Exit codes:
#   0 — both format-check and lint pass
#   non-zero — first failing check's exit code

set -uo pipefail

cd app && PY_RUN_APPROACH=local make format-check && PY_RUN_APPROACH=local make lint
