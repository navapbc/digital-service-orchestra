#!/usr/bin/env bash
# blast-radius.sh
#
# Blast-Radius Gate: Blast Radius Annotation
# Evaluates a file's blast radius by checking convention heuristics and fan-in
# (how many other modules import it). This is a modifier gate — it annotates
# the routing decision made by primary gates, never drives it.
#
# Usage:
#   blast-radius.sh <file_path> [repo_root]
#   blast-radius.sh <file_path> [--repo-root <path>]
#
# Arguments:
#   file_path   — Absolute path to the file being analyzed
#   repo_root   — (optional) Repo root for fan-in search; positional arg 2
#                 or --repo-root flag. Defaults to git rev-parse --show-toplevel.
#
# Output: JSON conforming to gate-signal-schema.md
#   gate_id:     "blast_radius"
#   triggered:   true if file matches a convention OR has fan-in > 0
#   signal_type: "modifier" (ALWAYS)
#   evidence:    human-readable annotation starting with "Note:"
#   confidence:  "high" | "medium" | "low"
#
# Always exits 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────

FILE_PATH=""
REPO_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            REPO_ROOT="$2"
            shift 2
            ;;
        --repo-root=*)
            REPO_ROOT="${1#--repo-root=}"
            shift
            ;;
        -*)
            shift
            ;;
        *)
            if [[ -z "$FILE_PATH" ]]; then
                FILE_PATH="$1"
            elif [[ -z "$REPO_ROOT" ]]; then
                # Second positional argument is repo root
                REPO_ROOT="$1"
            fi
            shift
            ;;
    esac
done

# Default repo root to git toplevel
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
fi

# ── Format check config resolution ───────────────────────────────────────────

_FORMAT_CHECK_EVIDENCE=""
CMD_FORMAT_CHECK=""
_fc_config=""
if [[ -n "${WORKFLOW_CONFIG_FILE:-}" && -f "${WORKFLOW_CONFIG_FILE}" ]]; then
    _fc_config="${WORKFLOW_CONFIG_FILE}"
elif [[ -f "$REPO_ROOT/.claude/dso-config.conf" ]]; then
    _fc_config="$REPO_ROOT/.claude/dso-config.conf"
fi
if [[ -n "$_fc_config" && -f "$SCRIPT_DIR/../read-config.sh" ]]; then
    CMD_FORMAT_CHECK=$("$SCRIPT_DIR/../read-config.sh" "commands.format_check" "$_fc_config" 2>/dev/null || true)
fi
if [[ -z "$CMD_FORMAT_CHECK" ]]; then
    echo "[DSO WARN] commands.format_check not configured — skipping format check in gate-2b." >&2
else
    # Run format check; capture output as evidence
    _fc_out=$(eval "$CMD_FORMAT_CHECK" 2>&1) && _fc_exit=0 || _fc_exit=$?
    if [[ "$_fc_exit" -ne 0 ]]; then
        _FORMAT_CHECK_EVIDENCE="Format check failed: $_fc_out"
    fi
fi

# ── JSON output helper ────────────────────────────────────────────────────────

emit_signal() {
    local triggered="$1"
    local evidence="$2"
    local confidence="$3"
    # Append format check evidence when non-empty
    if [[ -n "${_FORMAT_CHECK_EVIDENCE:-}" ]]; then
        evidence="${evidence}; ${_FORMAT_CHECK_EVIDENCE}"
    fi
    local py_bool="True"
    [[ "$triggered" == "false" ]] && py_bool="False"
    python3 -c "
import json, sys
evidence = sys.argv[1]
confidence = sys.argv[2]
triggered = $py_bool
print(json.dumps({
    'gate_id': 'blast_radius',
    'triggered': triggered,
    'signal_type': 'modifier',
    'evidence': evidence,
    'confidence': confidence
}))
" "$evidence" "$confidence"
}

# ── Convention heuristics ─────────────────────────────────────────────────────
# Returns the convention label if the file matches a known convention pattern,
# or empty string if no match.

detect_convention() {
    local filepath="$1"
    local basename
    basename="$(basename "$filepath")"
    local dirpart
    dirpart="$(dirname "$filepath")"

    # Package manifests
    case "$basename" in
        pyproject.toml|package.json|Gemfile|requirements.txt)
            echo "package manifest"
            return
            ;;
    esac

    # CI/CD configs
    case "$basename" in
        .gitlab-ci.yml|Jenkinsfile)
            echo "CI config"
            return
            ;;
    esac

    # GitHub Actions workflows: .github/workflows/*
    if [[ "$filepath" == */.github/workflows/* ]] || [[ "$dirpart" == */.github/workflows ]]; then
        echo "CI config"
        return
    fi

    # Schema / migration files
    case "$basename" in
        schema.*)
            echo "schema/migration"
            return
            ;;
    esac
    if [[ "$filepath" == */migrations/* ]] || [[ "$filepath" == */alembic/* ]]; then
        echo "schema/migration"
        return
    fi

    # Entry points
    case "$basename" in
        main.py|app.py|manage.py|index.js|index.ts)
            echo "entry point"
            return
            ;;
    esac

    echo ""
}

# ── Fan-in analysis ───────────────────────────────────────────────────────────
# Count how many files in repo_root import the target file.
# Primary: ast-grep; Fallback: grep-based.

count_fan_in() {
    local filepath="$1"
    local repo_root="$2"

    local basename
    basename="$(basename "$filepath")"
    # Strip common extensions to get the module name
    local module_name="${basename%.*}"

    if [[ -z "${BLAST_RADIUS_GATE_SKIP_AST_GREP:-}" ]] && command -v ast-grep >/dev/null 2>&1; then
        _count_fan_in_ast_grep "$filepath" "$repo_root" "$module_name"
    else
        _count_fan_in_grep "$filepath" "$repo_root" "$module_name"
    fi
}

_count_fan_in_ast_grep() {
    local filepath="$1"
    local repo_root="$2"
    local module_name="$3"

    # Collect all importing files into a single deduplicated set using Python.
    # Three sources: ast-grep `import $MODULE`, ast-grep `from $MODULE import`,
    # and grep for dotted imports that ast-grep's simple patterns miss.
    local all_files_tmpfile
    all_files_tmpfile="$(mktemp)"

    # Source 1: ast-grep `import $module_name`
    ast-grep --lang python \
        --pattern "import $module_name" \
        --json \
        "$repo_root" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for match in data:
        f = match.get('file', match.get('path', ''))
        if f: print(f)
except Exception:
    pass
" >> "$all_files_tmpfile" 2>/dev/null

    # Source 2: ast-grep `from $module_name import ...`
    ast-grep --lang python \
        --pattern "from $module_name import \$_" \
        --json \
        "$repo_root" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for match in data:
        f = match.get('file', match.get('path', ''))
        if f: print(f)
except Exception:
    pass
" >> "$all_files_tmpfile" 2>/dev/null

    # Source 3: grep for dotted imports (e.g., `import src.module_name`,
    # `from src.module_name import func`) that ast-grep's patterns miss
    grep -rl --include='*.py' \
        -e "import [a-zA-Z_][a-zA-Z0-9_.]*\.$module_name" \
        -e "from [a-zA-Z_][a-zA-Z0-9_.]*\.$module_name import" \
        "$repo_root" 2>/dev/null >> "$all_files_tmpfile"

    # Deduplicate, exclude the target file, count unique importing files
    local union_count
    union_count=$(sort -u "$all_files_tmpfile" | grep -vF "$filepath" | wc -l | tr -d ' ')
    rm -f "$all_files_tmpfile"

    echo "${union_count:-0}"
}

_count_fan_in_grep() {
    local filepath="$1"
    local repo_root="$2"
    local module_name="$3"

    # Use grep to find all files that reference the module by name
    # Patterns:
    #   import <module_name>
    #   from ... import <module_name>
    #   from <module_name>... import ...
    #   import ...<module_name>
    local count=0
    local matched_files=()

    # Collect all files that reference the module name in an import context.
    # We search for the module name as a substring — this catches all import styles:
    #   import module_name
    #   import pkg.module_name
    #   from pkg.module_name import ...
    #   from pkg import module_name
    while IFS= read -r match_file; do
        # Exclude the file itself
        local abs_match abs_target
        abs_match="$(realpath "$match_file" 2>/dev/null || echo "$match_file")"
        abs_target="$(realpath "$filepath" 2>/dev/null || echo "$filepath")"
        if [[ "$abs_match" != "$abs_target" ]]; then
            matched_files+=("$abs_match")
        fi
    done < <(grep -Frl -e "${module_name}" "$repo_root" 2>/dev/null | sort -u || true)

    # Deduplicate
    local unique_files
    unique_files="$(printf '%s\n' "${matched_files[@]:-}" | sort -u | grep -c . 2>/dev/null || echo 0)"

    echo "$unique_files"
}

# ── Main logic ────────────────────────────────────────────────────────────────

main() {
    if [[ -z "$FILE_PATH" ]]; then
        emit_signal "false" "Note: No file path provided for blast radius analysis." "low"
        exit 0
    fi

    local basename
    basename="$(basename "$FILE_PATH")"

    # 1. Check convention heuristics
    local convention
    convention="$(detect_convention "$FILE_PATH")"

    # 2. Fan-in analysis
    local fan_in=0
    fan_in="$(count_fan_in "$FILE_PATH" "$REPO_ROOT" 2>/dev/null || echo 0)"
    # Ensure it's a number
    fan_in="${fan_in//[^0-9]/}"
    : "${fan_in:=0}"

    # 3. Build evidence and determine triggered state
    local triggered=false
    local evidence_parts=()
    local confidence="medium"

    if [[ -n "$convention" ]]; then
        triggered=true
        confidence="high"
        # Fan-in line mentions both convention and import count
        if [[ "$fan_in" -gt 0 ]]; then
            evidence_parts+=("Note: $basename is a $convention, imported by $fan_in modules")
        else
            evidence_parts+=("Note: $basename is a $convention")
        fi
    elif [[ "$fan_in" -gt 0 ]]; then
        triggered=true
        confidence="medium"
        evidence_parts+=("Note: $basename is imported by $fan_in modules")
    fi

    if [[ "$triggered" == "true" ]]; then
        local evidence
        evidence="$(IFS='; '; echo "${evidence_parts[*]}")"
        emit_signal "true" "$evidence" "$confidence"
    else
        # Not triggered — still must provide a non-empty evidence string
        emit_signal "false" "Note: $basename has no convention match and no detected fan-in in the repository." "low"
    fi
}

main
