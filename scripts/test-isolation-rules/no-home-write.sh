#!/usr/bin/env bash
# no-home-write.sh — Test isolation rule
#
# Detects writes targeting $HOME or ~ paths without a preceding temp HOME override.
# A "temp HOME override" is a line like: HOME=$(mktemp ...) or HOME=/tmp/... etc.
#
# Rule contract (see check-test-isolation.sh):
#   - Receives file path as $1
#   - Outputs violations as file:line:no-home-write:message to stdout
#   - Exits 0 if no violations found
#
# Suppression: lines with "# isolation-ok:" are handled by the harness, but
# this rule also respects them to work correctly standalone.

set -uo pipefail

FILE="${1:-}"
if [[ -z "$FILE" ]] || [[ ! -f "$FILE" ]]; then
    exit 0
fi

RULE_NAME="no-home-write"
VIOLATIONS=0

# Only check shell/bash files — Python tests don't write to $HOME via shell patterns
case "$FILE" in
    *.sh|*.bash) ;;
    *) exit 0 ;;
esac

# Check if the file has a HOME override (HOME=... with mktemp, /tmp, or similar)
# before any $HOME/~ usage. We look for lines like:
#   HOME=$(mktemp ...)
#   HOME=/tmp/...
#   export HOME=$(mktemp ...)
#   export HOME=/tmp/...
has_home_override=false
home_override_line=0

while IFS= read -r line_content; do
    (( home_override_line++ ))
    # Skip comments and empty lines
    stripped="${line_content##*([[:space:]])}"
    [[ -z "$stripped" ]] && continue
    [[ "$stripped" == \#* ]] && continue

    # Check for HOME override patterns
    if echo "$line_content" | grep -qE '(^|export\s+)HOME=\$\(mktemp|HOME=/tmp|HOME=\$\{?TMPDIR'; then
        has_home_override=true
        break
    fi
done < "$FILE"

# Patterns that indicate writes to HOME or ~ paths
# We scan each line for these patterns
LINENUM=0
while IFS= read -r line_content; do
    (( LINENUM++ ))

    # Skip empty lines and pure comments
    stripped="${line_content##*([[:space:]])}"
    [[ -z "$stripped" ]] && continue
    [[ "$stripped" == \#* ]] && continue

    # Skip lines with suppression comment
    if echo "$line_content" | grep -q '# isolation-ok:'; then
        continue
    fi

    # If we already found a HOME override before this line, skip
    if $has_home_override && (( LINENUM > home_override_line )); then
        continue
    fi

    # Check for write patterns targeting $HOME or ~
    is_violation=false
    message=""

    # Pattern: > $HOME or >> $HOME (redirect to $HOME path)
    if echo "$line_content" | grep -qE '>>?\s*\$HOME'; then
        is_violation=true
        message="Writes to \$HOME path without temp HOME override"
    # Pattern: > ~/ or >> ~/ (redirect to ~ path)
    elif echo "$line_content" | grep -qE '>>?\s*~/'; then
        is_violation=true
        message="Writes to ~ path without temp HOME override"
    # Pattern: mkdir ... $HOME
    elif echo "$line_content" | grep -qE 'mkdir\s+.*\$HOME'; then
        is_violation=true
        message="Creates directory under \$HOME without temp HOME override"
    # Pattern: mkdir ... ~/
    elif echo "$line_content" | grep -qE 'mkdir\s+.*~/'; then
        is_violation=true
        message="Creates directory under ~ without temp HOME override"
    # Pattern: cp ... $HOME (cp targeting $HOME as destination)
    elif echo "$line_content" | grep -qE 'cp\s+\S+\s+\$HOME'; then
        is_violation=true
        message="Copies file to \$HOME without temp HOME override"
    # Pattern: cp ... ~/ (cp targeting ~ as destination)
    elif echo "$line_content" | grep -qE 'cp\s+\S+\s+~/'; then
        is_violation=true
        message="Copies file to ~ without temp HOME override"
    fi

    if $is_violation; then
        echo "$FILE:$LINENUM:$RULE_NAME:$message"
        (( VIOLATIONS++ ))
    fi
done < "$FILE"

if [[ $VIOLATIONS -gt 0 ]]; then
    exit 1
fi

exit 0
