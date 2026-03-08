# Makefile — convention-based project for stack detection testing
# This project has no pyproject.toml, package.json, Cargo.toml, or go.mod.
# detect-stack.sh should detect it as "convention-based" based on this Makefile
# having standard test/lint/format targets.

.PHONY: test lint format format-check validate test-unit

test:
	@echo "Running full test suite..."
	@bash tests/run_all.sh

test-unit:
	@echo "Running unit tests..."
	@bash tests/run_unit.sh

lint:
	@echo "Running linter..."
	@shellcheck scripts/*.sh

format:
	@echo "Formatting code..."
	@shfmt -w scripts/*.sh

format-check:
	@echo "Checking formatting..."
	@shfmt -d scripts/*.sh

validate: lint format-check test
	@echo "Validation complete."
