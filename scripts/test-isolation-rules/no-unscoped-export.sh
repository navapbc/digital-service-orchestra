#!/usr/bin/env bash
# no-unscoped-export.sh — Test isolation rule
#
# Detects `export VAR=value` in bash test files without containment
# (subshell wrapper or save/restore pattern).
#
# Unscoped exports leak environment variables between tests,
# causing hidden coupling and non-deterministic failures.
#
# Rule contract:
#   - Receives a file path as $1
#   - Outputs violations as file:line:no-unscoped-export:message to stdout
#   - Exits 0 if no violations, 1 if violations found
#
# Containment patterns (accepted):
#   - Subshell: export inside ( ... ) block
#   - Save/restore: _OLD_VAR="${VAR:-}" before export, export VAR="$_OLD_VAR" after
#
# Suppression:
#   - Lines with # isolation-ok: are filtered by the harness, not this rule

set -uo pipefail

file="${1:?Usage: no-unscoped-export.sh <file>}"

if [[ ! -f "$file" ]]; then
    echo "ERROR: File not found: $file" >&2
    exit 2
fi

# Only check shell/bash files — Python files don't use export
case "$file" in
    *.sh|*.bash) ;;
    *) exit 0 ;;
esac

violations=""
violation_count=0

# Track subshell nesting depth and save/restore context
subshell_depth=0
line_num=0

# First pass: identify which lines are inside subshells
declare -A in_subshell
declare -A has_save_restore

while IFS= read -r line; do
    (( line_num++ ))

    # Strip leading whitespace for pattern matching
    stripped="${line#"${line%%[![:space:]]*}"}"

    # Track subshell open/close — count ( and ) on each line
    # Only count standalone ( not $( or function()
    opens=$(echo "$line" | sed 's/\$(/\n/g; s/[a-zA-Z_]*()/\n/g' | grep -c '(' || true)
    closes=$(echo "$line" | sed 's/\$(/\n/g; s/[a-zA-Z_]*()/\n/g' | grep -c ')' || true)
    (( subshell_depth = subshell_depth + opens - closes )) || true
    if (( subshell_depth < 0 )); then
        subshell_depth=0
    fi

    in_subshell[$line_num]=$subshell_depth
done < "$file"

# Second pass: identify save/restore patterns
# A save/restore is: _OLD_VAR="${VAR:-}" ... export VAR=... ... export VAR="$_OLD_VAR"
# We track variables that have been saved
declare -A saved_vars
line_num=0

while IFS= read -r line; do
    (( line_num++ ))

    stripped="${line#"${line%%[![:space:]]*}"}"

    # Detect save pattern: _OLD_VARNAME="${VARNAME:-}" or similar
    if [[ "$stripped" =~ ^_[Oo][Ll][Dd]_([A-Za-z_][A-Za-z0-9_]*)= ]] || \
       [[ "$stripped" =~ ^_old_([A-Za-z_][A-Za-z0-9_]*)= ]] || \
       [[ "$stripped" =~ ^_OLD_([A-Za-z_][A-Za-z0-9_]*)= ]] || \
       [[ "$stripped" =~ ^_ORIG_([A-Za-z_][A-Za-z0-9_]*)= ]] || \
       [[ "$stripped" =~ ^_SAVE_([A-Za-z_][A-Za-z0-9_]*)= ]] || \
       [[ "$stripped" =~ ^_SAVED_([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        varname="${BASH_REMATCH[1]}"
        saved_vars["$varname"]=1
    fi
done < "$file"

# Third pass: find export violations
line_num=0

while IFS= read -r line; do
    (( line_num++ ))

    stripped="${line#"${line%%[![:space:]]*}"}"

    # Skip comments and blank lines
    [[ -z "$stripped" ]] && continue
    [[ "$stripped" == \#* ]] && continue

    # Match export VAR=value (but not bare `export VAR` without assignment)
    if [[ "$stripped" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        varname="${BASH_REMATCH[1]}"

        # Check containment: subshell
        depth="${in_subshell[$line_num]:-0}"
        if (( depth > 0 )); then
            continue
        fi

        # Check containment: save/restore pattern
        if [[ -n "${saved_vars[$varname]:-}" ]]; then
            continue
        fi

        # Check if this line is itself a restore (export VAR="$_OLD_VAR")
        if [[ "$stripped" =~ ^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\"?\$_[Oo][Ll][Dd]_ ]] || \
           [[ "$stripped" =~ ^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\"?\$_OLD_ ]] || \
           [[ "$stripped" =~ ^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\"?\$_ORIG_ ]] || \
           [[ "$stripped" =~ ^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\"?\$_SAVE_ ]] || \
           [[ "$stripped" =~ ^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\"?\$_SAVED_ ]]; then
            continue
        fi

        violations+="$file:$line_num:no-unscoped-export:export $varname without subshell or save/restore containment"$'\n'
        (( violation_count++ ))
    fi
done < "$file"

if (( violation_count > 0 )); then
    echo -n "$violations" | sed '/^$/d'
    exit 1
fi

exit 0
