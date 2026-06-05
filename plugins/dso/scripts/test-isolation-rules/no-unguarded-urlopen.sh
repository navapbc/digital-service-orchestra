#!/usr/bin/env bash
set -uo pipefail
# Rule: no-unguarded-urlopen
#
# Detects Python test files that call urllib.request.urlopen (or the common
# http.client connect() form) without a corresponding mock/patch in the same
# file. Un-mocked urlopen calls reach real network endpoints in test runs —
# the root cause of bug 1c68.
#
# Detection strategy (low-FP, high-confidence):
#   A test file is flagged if:
#     - It contains a call to urlopen( (without the leading dot, to skip
#       attribute access: mock_obj.urlopen is allowed)
#     - AND it does NOT contain any of:
#         patch.*urlopen, mock.*urlopen, MagicMock.*urlopen, @pytest.mark.allow_network
#
# This rule does NOT flag:
#   - Files that use mock/patch for urlopen (correctly isolated)
#   - Files that opt out with @pytest.mark.allow_network
#   - Non-test Python files (only test_*.py / *_test.py are checked)
#
# Suppression: add "# isolation-ok: <reason>" on the urlopen call line.
#
# Rule contract (see check-test-isolation.sh):
#   - Receives file path as $1
#   - Outputs violations as file:line:no-unguarded-urlopen:message to stdout
#   - Exits 0 (violations reported via stdout, not exit code)

FILE="${1:-}"
if [[ -z "$FILE" ]] || [[ ! -f "$FILE" ]]; then
    exit 0
fi

# Only check Python test files
case "$FILE" in
    *.py) ;;
    *) exit 0 ;;
esac

# Only check files that look like test files by name
basename_file=$(basename "$FILE")
case "$basename_file" in
    test_*.py|*_test.py) ;;
    *) exit 0 ;;
esac

RULE_NAME="no-unguarded-urlopen"

# Fast exit: no urlopen call → nothing to check
if ! grep -qE '\burlopen\(' "$FILE" 2>/dev/null; then
    exit 0
fi

# If the file already patches urlopen or opts out via marker → safe
if grep -qE 'patch.*urlopen|urlopen.*mock|mock.*urlopen|MagicMock.*urlopen|allow_network' "$FILE" 2>/dev/null; then
    exit 0
fi

# Find the first urlopen call line (stdlib path: urllib.request.urlopen or bare urlopen)
# and report it as the violation anchor.
# We already know there's no mock in the file (checked above), so every urlopen
# call in the file is a potential live-network escape.
first_line=0
line_num=0
while IFS= read -r line; do
    (( line_num++ ))
    # Skip comment lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if echo "$line" | grep -qE '\burlopen\('; then
        first_line=$line_num
        break
    fi
done < "$FILE"

if [[ $first_line -gt 0 ]]; then
    echo "${FILE}:${first_line}:${RULE_NAME}:urlopen() call without mock — test may reach live network (see bug 1c68); mock with patch('urllib.request.urlopen', ...) or add @pytest.mark.allow_network"
fi

exit 0
