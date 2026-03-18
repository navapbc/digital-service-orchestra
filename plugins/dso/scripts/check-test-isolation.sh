#!/usr/bin/env bash
set -uo pipefail
# check-test-isolation.sh — Test isolation rule harness
#
# Scans scripts/test-isolation-rules/ for executable rule files (*.sh),
# executes each rule against target test files, and reports violations.
#
# Rule contract:
#   - Each rule receives a file path as $1
#   - Outputs violations as file:line:rule-name:message to stdout
#   - Exits 0 if no violations found
#   - Non-zero exit from a crash is handled gracefully (logged, continues)
#
# Environment variables:
#   RULES_DIR     — Override the rules directory (default: scripts/test-isolation-rules/)
#   STAGED_ONLY   — When "true", only check files staged in git (git diff --cached --name-only)
#
# Usage:
#   scripts/check-test-isolation.sh <file1> [file2 ...]
#   scripts/check-test-isolation.sh --baseline <file1> [file2 ...]
#   scripts/check-test-isolation.sh --help
#   STAGED_ONLY=true scripts/check-test-isolation.sh <file1> [file2 ...]
#
# Exit codes:
#   0 — No violations found (or --baseline mode)
#   1 — Violations found (structured output to stdout)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

# Default rules directory; can be overridden via RULES_DIR env var
: "${RULES_DIR:=$REPO_ROOT/scripts/test-isolation-rules}"

# ---- Help / missing args ----
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "Usage: scripts/check-test-isolation.sh [--baseline] <file1> [file2 ...]"
    echo ""
    echo "Runs test isolation rules from $RULES_DIR against the given files."
    echo ""
    echo "Flags:"
    echo "  --baseline     Report-only mode: show violation summary, always exit 0"
    echo ""
    echo "Environment:"
    echo "  RULES_DIR      Override rules directory"
    echo "  STAGED_ONLY    When 'true', only check files staged in git"
    exit 0
fi

# ---- Auto-discover staged test files when STAGED_ONLY=true and no args ----
if [[ $# -eq 0 ]] && [[ "${STAGED_ONLY:-false}" == "true" ]]; then
    STAGED_TEST_FILES=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && STAGED_TEST_FILES+=("$REPO_ROOT/$f")
    done < <(cd "$REPO_ROOT" && git diff --cached --name-only 2>/dev/null | grep -E '^app/tests/.*\.py$' || true)
    if [[ ${#STAGED_TEST_FILES[@]} -eq 0 ]]; then
        exit 0
    fi
    set -- "${STAGED_TEST_FILES[@]}"
elif [[ $# -eq 0 ]]; then
    echo "Usage: scripts/check-test-isolation.sh [--baseline] <file1> [file2 ...]"
    echo ""
    echo "Runs test isolation rules from $RULES_DIR against the given files."
    echo ""
    echo "Flags:"
    echo "  --baseline     Report-only mode: show violation summary, always exit 0"
    echo ""
    echo "Environment:"
    echo "  RULES_DIR      Override rules directory"
    echo "  STAGED_ONLY    When 'true', only check files staged in git"
    exit 0
fi

# ---- Parse --baseline flag ----
BASELINE_MODE=false
if [[ "${1:-}" == "--baseline" ]]; then
    BASELINE_MODE=true
    shift
fi

# ---- Collect target files ----
TARGET_FILES=("$@")

# If STAGED_ONLY is true, filter to only staged files
if [[ "${STAGED_ONLY:-false}" == "true" ]]; then
    STAGED=$(cd "$REPO_ROOT" && git diff --cached --name-only 2>/dev/null || true)
    FILTERED=()
    for f in "${TARGET_FILES[@]}"; do
        # Normalize to repo-relative path for comparison
        rel_path="${f#"$REPO_ROOT"/}"
        if echo "$STAGED" | grep -qxF "$rel_path"; then
            FILTERED+=("$f")
        fi
    done
    TARGET_FILES=("${FILTERED[@]+"${FILTERED[@]}"}")
    if [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
        exit 0
    fi
fi

# ---- Discover rules ----
if [[ ! -d "$RULES_DIR" ]]; then
    echo "WARNING: Rules directory not found: $RULES_DIR" >&2
    exit 0
fi

RULES=()
for rule in "$RULES_DIR"/*.sh; do
    [[ -f "$rule" ]] || continue
    [[ -x "$rule" ]] || continue
    RULES+=("$rule")
done

if [[ ${#RULES[@]} -eq 0 ]]; then
    # No rules to run
    exit 0
fi

# ---- Execute rules against each file ----
VIOLATIONS=""
VIOLATION_COUNT=0

for target in "${TARGET_FILES[@]}"; do
    [[ -f "$target" ]] || continue

    for rule in "${RULES[@]}"; do
        rule_name=$(basename "$rule" .sh)

        # Run the rule, capture output; handle crashes gracefully
        rule_output=""
        if ! rule_output=$("$rule" "$target" 2>/dev/null); then
            rule_exit=$?
            # Rule crashed (non-zero exit without producing violations is a crash)
            if [[ -z "$rule_output" ]]; then
                echo "WARNING: Rule '$rule_name' crashed (exit $rule_exit) on $target — skipping" >&2
                continue
            fi
        fi

        # Filter out suppressed lines (# isolation-ok: <reason>)
        if [[ -n "$rule_output" ]]; then
            while IFS= read -r violation_line; do
                [[ -z "$violation_line" ]] && continue

                # Extract the line number from the structured output (file:line:rule:message)
                viol_linenum=$(echo "$violation_line" | cut -d: -f2)

                # Check if the source line has a suppression comment
                if [[ -n "$viol_linenum" ]] && [[ "$viol_linenum" =~ ^[0-9]+$ ]]; then
                    source_line=$(sed -n "${viol_linenum}p" "$target" 2>/dev/null || true)
                    if echo "$source_line" | grep -q '# isolation-ok:'; then
                        continue
                    fi
                fi

                VIOLATIONS+="$violation_line"$'\n'
                (( VIOLATION_COUNT++ ))
            done <<< "$rule_output"
        fi
    done
done

# ---- Report results ----
if [[ "$BASELINE_MODE" == "true" ]]; then
    # Baseline mode: output summary report, always exit 0
    echo "=== Baseline Scan Report ==="
    echo ""
    echo "Total violations: $VIOLATION_COUNT"

    if [[ $VIOLATION_COUNT -gt 0 ]]; then
        # Count violations by rule name (field 3 in file:line:rule:message)
        echo ""
        echo "By rule:"
        echo "$VIOLATIONS" | sed '/^$/d' | cut -d: -f3 | sort | uniq -c | sort -rn | while read -r count rule; do
            echo "  $rule: $count"
        done

        # Count violations by file extension
        echo ""
        echo "By file type:"
        echo "$VIOLATIONS" | sed '/^$/d' | cut -d: -f1 | while read -r filepath; do
            case "$filepath" in
                *.py) echo ".py" ;;
                *.sh) echo ".sh" ;;
                *) echo ".other" ;;
            esac
        done | sort | uniq -c | sort -rn | while read -r count ext; do
            echo "  $ext: $count"
        done
    fi
    exit 0
fi

if [[ $VIOLATION_COUNT -gt 0 ]]; then
    echo "$VIOLATIONS" | sed '/^$/d'
    exit 1
fi

exit 0
