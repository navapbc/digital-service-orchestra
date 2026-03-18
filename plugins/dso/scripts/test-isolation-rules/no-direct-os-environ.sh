#!/usr/bin/env bash
set -uo pipefail
# Rule: no-direct-os-environ
#
# Scans Python test files (test_*.py) for direct os.environ mutation
# within test function bodies. Tests should use monkeypatch.setenv instead.
#
# Detected patterns:
#   - os.environ["..."] = ...    (direct assignment)
#   - os.environ.setdefault(...) (setdefault call)
#   - os.environ.update(...)     (update call)
#
# Output format: file:line:no-direct-os-environ:message
#
# Contract:
#   - Receives file path as $1
#   - Outputs violations to stdout
#   - Exits 0 (violations are reported via stdout, not exit code)

set -uo pipefail

file="$1"

# Only check Python files
case "$file" in
    *.py) ;;
    *) exit 0 ;;
esac

line_num=0
in_test_body=0

while IFS= read -r line; do
    (( line_num++ ))

    # Detect test function definition (def test_...)
    if echo "$line" | grep -qE '^def test_|^    def test_|^[[:space:]]*def test_'; then
        in_test_body=1
        continue
    fi

    # Detect non-test function/class definition (reset)
    # Handles both top-level (^def) and indented (^[[:space:]]*def) definitions
    # to correctly reset in_test_body for class helper methods after test methods
    if echo "$line" | grep -qE '^[[:space:]]*def [a-z]' && ! echo "$line" | grep -qE '^[[:space:]]*def test_'; then
        in_test_body=0
        continue
    fi
    if echo "$line" | grep -qE '^[[:space:]]*class '; then
        in_test_body=0
        continue
    fi

    # Only flag violations inside test function bodies
    if [[ "$in_test_body" -eq 1 ]]; then
        # Pattern 1: os.environ["..."] = ... or os.environ['...'] = ...
        # Exclude == (comparison) and !=
        if echo "$line" | grep -qE 'os\.environ\[.*\]\s*=' && ! echo "$line" | grep -qE 'os\.environ\[.*\]\s*=='; then
            echo "$file:$line_num:no-direct-os-environ:Use monkeypatch.setenv instead of os.environ[...] = ..."
        # Pattern 2: os.environ.setdefault(...)
        elif echo "$line" | grep -qE 'os\.environ\.setdefault\s*\('; then
            echo "$file:$line_num:no-direct-os-environ:Use monkeypatch.setenv instead of os.environ.setdefault(...)"
        # Pattern 3: os.environ.update(...)
        elif echo "$line" | grep -qE 'os\.environ\.update\s*\('; then
            echo "$file:$line_num:no-direct-os-environ:Use monkeypatch.setenv instead of os.environ.update(...)"
        fi
    fi
done < "$file"

exit 0
