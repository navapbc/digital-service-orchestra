#!/usr/bin/env bash
# plugins/dso/scripts/review-complexity-classifier.sh
# Deterministic complexity classifier for the DSO tiered review system.
#
# Accepts a unified diff on stdin, scores it on 7 factors, applies floor rules,
# and outputs a JSON object per the classifier-tier-output contract.
#
# Usage:
#   review-complexity-classifier.sh < diff_file
#   cat diff | review-complexity-classifier.sh
#
# Exit: 0 on success (valid JSON on stdout); non-zero on failure.
# On failure, the caller (REVIEW-WORKFLOW.md) defaults to standard tier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reject unknown flags
for _arg in "$@"; do
    case "$_arg" in
        -*) echo "ERROR: unknown flag: $_arg" >&2; exit 1 ;;
    esac
done

# Resolve REPO_ROOT
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"

# Source deps.sh for get_artifacts_dir, _load_allowlist_patterns, _allowlist_to_grep_regex
DEPS_PATH=""
if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/plugins/dso/hooks/lib/deps.sh" ]]; then
    DEPS_PATH="$REPO_ROOT/plugins/dso/hooks/lib/deps.sh"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "$CLAUDE_PLUGIN_ROOT/hooks/lib/deps.sh" ]]; then
    DEPS_PATH="$CLAUDE_PLUGIN_ROOT/hooks/lib/deps.sh"
fi
if [[ -n "$DEPS_PATH" ]]; then
    source "$DEPS_PATH"
fi

# Source merge-state.sh for ms_is_merge_in_progress and ms_is_rebase_in_progress
# _MERGE_STATE_GIT_DIR env var is the test isolation seam (replaces legacy MOCK_MERGE_HEAD,
# MOCK_REBASE_HEAD, and CLASSIFIER_GIT_DIR overrides).
if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/plugins/dso/hooks/lib/merge-state.sh" ]]; then
    source "$REPO_ROOT/plugins/dso/hooks/lib/merge-state.sh"
elif [[ -f "$(cd "$SCRIPT_DIR/.." && pwd)/hooks/lib/merge-state.sh" ]]; then
    source "$(cd "$SCRIPT_DIR/.." && pwd)/hooks/lib/merge-state.sh"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "$CLAUDE_PLUGIN_ROOT/hooks/lib/merge-state.sh" ]]; then
    source "$CLAUDE_PLUGIN_ROOT/hooks/lib/merge-state.sh"
fi

# --- Read diff from stdin ---
DIFF_CONTENT="$(cat)"
if [[ -z "$DIFF_CONTENT" ]]; then
    # No diff input — score zero (empty changeset)
    printf '{"blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"selected_tier":"light","diff_size_lines":0,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
    exit 0
fi

# --- Extract changed file paths from diff ---
declare -a CHANGED_FILES=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    CHANGED_FILES+=("$line")
done < <(printf '%s\n' "$DIFF_CONTENT" | grep -E '^diff --git a/' | sed 's|^diff --git a/.* b/||' || true)

if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    printf '{"blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"selected_tier":"light","diff_size_lines":0,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
    exit 0
fi

# --- Load allowlist patterns ---
ALLOWLIST_PATH="${REPO_ROOT:+$REPO_ROOT/plugins/dso/hooks/lib/review-gate-allowlist.conf}"
ALLOWLIST_REGEX=""
if [[ -n "${ALLOWLIST_PATH:-}" && -f "$ALLOWLIST_PATH" ]] && declare -f _load_allowlist_patterns &>/dev/null; then
    _AL_PATTERNS=$(_load_allowlist_patterns "$ALLOWLIST_PATH" 2>/dev/null || echo "")
    if [[ -n "$_AL_PATTERNS" ]] && declare -f _allowlist_to_grep_regex &>/dev/null; then
        ALLOWLIST_REGEX=$(_allowlist_to_grep_regex "$_AL_PATTERNS" 2>/dev/null || echo "")
    fi
fi

is_allowlist_exempt() {
    local file="$1"
    [[ -z "$ALLOWLIST_REGEX" ]] && return 1
    printf '%s\n' "$file" | grep -qE "$ALLOWLIST_REGEX" 2>/dev/null && return 0
    return 1
}

# --- Load behavioral patterns from config ---
declare -a BEHAVIORAL_PATTERNS=()
READ_CONFIG=""
if [[ -f "$SCRIPT_DIR/read-config.sh" ]]; then
    READ_CONFIG="$SCRIPT_DIR/read-config.sh"
elif [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/plugins/dso/scripts/read-config.sh" ]]; then
    READ_CONFIG="$REPO_ROOT/plugins/dso/scripts/read-config.sh"
fi

if [[ -n "$READ_CONFIG" ]]; then
    RAW_PATTERNS=$("$READ_CONFIG" review.behavioral_patterns 2>/dev/null || echo "")
    if [[ -n "$RAW_PATTERNS" ]]; then
        IFS=';' read -ra BEHAVIORAL_PATTERNS <<< "$RAW_PATTERNS"
    fi
fi

is_behavioral_file() {
    local file="$1"
    [[ ${#BEHAVIORAL_PATTERNS[@]} -eq 0 ]] && return 1
    local pattern
    for pattern in "${BEHAVIORAL_PATTERNS[@]}"; do
        [[ -z "$pattern" ]] && continue
        # shellcheck disable=SC2254
        case "$file" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# --- Safeguard file patterns (CLAUDE.md rule #20) ---
declare -a SAFEGUARD_PATTERNS=(
    "plugins/dso/skills/*"
    "plugins/dso/hooks/*"
    "plugins/dso/hooks/**/*"
    "plugins/dso/docs/workflows/*"
    "plugins/dso/docs/workflows/**/*"
    "plugins/dso/scripts/*"
    "plugins/dso/commands/*"
    "CLAUDE.md"
    "plugins/dso/hooks/lib/review-gate-allowlist.conf"
)

is_safeguard_file() {
    local file="$1"
    local pattern
    for pattern in "${SAFEGUARD_PATTERNS[@]}"; do
        # shellcheck disable=SC2254
        case "$file" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# --- Critical path patterns ---
is_critical_path_file() {
    local file="$1"
    case "$file" in
        */db/*|*/database/*|*/auth/*|*/security/*|*/routes/*|*/handlers/*|*/request/*|*/middleware/*|*/persistence/*) return 0 ;;
    esac
    return 1
}

# --- Security-sensitive path patterns ---
is_security_sensitive() {
    local file="$1"
    case "$file" in
        */auth/*|*/security/*|*/crypto/*|*/encryption/*|*/session/*|*/oauth/*) return 0 ;;
    esac
    return 1
}

# --- Performance-sensitive path patterns ---
is_performance_sensitive() {
    local file="$1"
    case "$file" in
        */db/*|*/database/*|*/cache/*|*/query/*|*/pool/*|*/persistence/*) return 0 ;;
    esac
    return 1
}

# --- Test file detection ---
is_test_file() {
    local file="$1"
    case "$file" in
        tests/*|test/*|*/test_*|*/tests/*|*_test.*|*.test.*) return 0 ;;
    esac
    return 1
}

# --- Generated file detection ---
is_generated_file() {
    local file="$1"
    case "$file" in
        */migrations/*|*.lock|*package-lock.json|*.generated.*|*/generated/*) return 0 ;;
    esac
    return 1
}

# --- Classify files ---
declare -a EXEMPT_FILES=()
declare -a SCORING_FILES=()
BEHAVIORAL_COUNT=0
declare -a DELETED_TEST_FILES=()
declare -a DELETED_SOURCE_FILES=()

for file in "${CHANGED_FILES[@]}"; do
    if is_allowlist_exempt "$file"; then
        EXEMPT_FILES+=("$file")
        continue
    fi
    SCORING_FILES+=("$file")
    if is_behavioral_file "$file"; then
        BEHAVIORAL_COUNT=$(( BEHAVIORAL_COUNT + 1 ))
    fi
done

# If all files are exempt, output zero scores
if [[ ${#SCORING_FILES[@]} -eq 0 ]]; then
    printf '{"blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"selected_tier":"light","diff_size_lines":0,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
    exit 0
fi

# Build list of deleted files by looking for "+++ /dev/null"
_CURRENT_FILE=""
while IFS= read -r line; do
    if [[ "$line" =~ ^diff\ --git\ a/.*\ b/(.*) ]]; then
        _CURRENT_FILE="${BASH_REMATCH[1]}"
    elif [[ "$line" == "+++ /dev/null" && -n "$_CURRENT_FILE" ]]; then
        if is_test_file "$_CURRENT_FILE"; then
            DELETED_TEST_FILES+=("$_CURRENT_FILE")
        else
            DELETED_SOURCE_FILES+=("$_CURRENT_FILE")
        fi
    fi
done <<< "$DIFF_CONTENT"

# ============================================================
# Factor 1: blast_radius (0-3)
# ============================================================
_blast_radius() {
    local max_count=0
    local file
    for file in "${SCORING_FILES[@]}"; do
        is_test_file "$file" && continue
        # Skip non-source files (docs, config, markdown) — they are not imported
        case "$file" in
            *.md|*.txt|*.rst|*.json|*.yaml|*.yml|*.toml|*.cfg|*.ini|*.conf) continue ;;
        esac
        local bname
        bname=$(basename "$file")
        local name_no_ext="${bname%.*}"
        [[ -z "$name_no_ext" ]] && continue

        local count=0
        if [[ -n "$REPO_ROOT" ]] && command -v git &>/dev/null; then
            count=$(git grep -rl "$name_no_ext" -- "$REPO_ROOT" 2>/dev/null | wc -l | tr -d '[:space:]') || true
            count=${count:-0}
            # Subtract self-reference
            if [[ "$count" -gt 0 ]] 2>/dev/null; then
                count=$(( count - 1 ))
            else
                count=0
            fi
        fi
        if [[ "$count" -gt "$max_count" ]] 2>/dev/null; then
            max_count=$count
        fi
    done

    if (( max_count >= 10 )); then echo 3
    elif (( max_count >= 5 )); then echo 2
    elif (( max_count >= 2 )); then echo 1
    else echo 0; fi
}

# ============================================================
# Factor 2: critical_path (0-3)
# ============================================================
_critical_path() {
    local crit_count=0
    local file
    for file in "${SCORING_FILES[@]}"; do
        if is_critical_path_file "$file"; then
            crit_count=$(( crit_count + 1 ))
        fi
    done

    if (( crit_count >= 3 )); then echo 3
    elif (( crit_count >= 2 )); then echo 2
    elif (( crit_count >= 1 )); then echo 1
    else echo 0; fi
}

# ============================================================
# Factor 3: anti_shortcut (0-3)
# ============================================================
_anti_shortcut() {
    local noqa_n type_ign_n skip_n total
    # Only count markers in added lines (^+ prefix), matching _has_anti_shortcut_signal behavior
    noqa_n=$(printf '%s\n' "$DIFF_CONTENT" | grep -c '^+.*# noqa' || true)
    type_ign_n=$(printf '%s\n' "$DIFF_CONTENT" | grep -c '^+.*type: *ignore' || true)
    skip_n=$(printf '%s\n' "$DIFF_CONTENT" | grep -c '^+.*pytest\.mark\.skip' || true)
    noqa_n=${noqa_n:-0}
    type_ign_n=${type_ign_n:-0}
    skip_n=${skip_n:-0}
    total=$(( noqa_n + type_ign_n + skip_n ))
    if (( total > 3 )); then echo 3; else echo "$total"; fi
}

# ============================================================
# Factor 4: staleness (0-2)
# ============================================================
_staleness() {
    local max_days=0
    local now
    now=$(date +%s 2>/dev/null || echo "0")

    if [[ "$now" -eq 0 ]] 2>/dev/null || [[ -z "$REPO_ROOT" ]]; then
        echo 0
        return
    fi

    local file
    for file in "${SCORING_FILES[@]}"; do
        local last_mod
        last_mod=$(git log -1 --format=%ct -- "$file" 2>/dev/null || echo "")
        if [[ -n "$last_mod" && "$last_mod" -gt 0 ]] 2>/dev/null; then
            local days=$(( (now - last_mod) / 86400 ))
            if (( days > max_days )); then
                max_days=$days
            fi
        fi
    done

    if (( max_days >= 91 )); then echo 2
    elif (( max_days >= 31 )); then echo 1
    else echo 0; fi
}

# ============================================================
# Factor 5: cross_cutting (0-2)
# ============================================================
_cross_cutting() {
    local -A top_dirs=()
    local file
    for file in "${SCORING_FILES[@]}"; do
        local top_dir="${file%%/*}"
        if [[ "$top_dir" == "$file" ]]; then
            top_dir="__root__"
        fi
        top_dirs["$top_dir"]=1
    done

    local dir_count=${#top_dirs[@]}
    if (( dir_count >= 3 )); then echo 2
    elif (( dir_count >= 2 )); then echo 1
    else echo 0; fi
}

# ============================================================
# Factor 6: diff_lines (0-1)
# ============================================================
_diff_lines() {
    local total_lines=0
    local cur_file=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^diff\ --git\ a/.*\ b/(.*) ]]; then
            cur_file="${BASH_REMATCH[1]}"
        elif [[ "${line:0:1}" == "+" && "${line:1:1}" != "+" && -n "$cur_file" ]]; then
            if ! is_test_file "$cur_file" && [[ "$cur_file" != .tickets-tracker/* ]]; then
                total_lines=$(( total_lines + 1 ))
            fi
        fi
    done <<< "$DIFF_CONTENT"

    if (( total_lines >= 50 )); then echo 1; else echo 0; fi
}

# ============================================================
# Factor 7: change_volume (0-1)
# ============================================================
_change_volume() {
    local sb_count=0
    local file
    for file in "${SCORING_FILES[@]}"; do
        if is_behavioral_file "$file" || ! is_test_file "$file"; then
            sb_count=$(( sb_count + 1 ))
        fi
    done

    # Behavioral files get full scoring weight — if any behavioral file is present,
    # ensure minimum change_volume of 1
    if (( BEHAVIORAL_COUNT > 0 )); then
        echo 1
        return
    fi

    if (( sb_count >= 5 )); then echo 1; else echo 0; fi
}

# ============================================================
# Floor rule checks
# ============================================================
_has_anti_shortcut_signal() {
    printf '%s\n' "$DIFF_CONTENT" | grep -qE '^\+.*(# noqa|type: *ignore|pytest\.mark\.skip)' 2>/dev/null && return 0
    return 1
}

_has_critical_path_file() {
    local file
    for file in "${SCORING_FILES[@]}"; do
        is_critical_path_file "$file" && return 0
    done
    return 1
}

_has_safeguard_file() {
    local file
    for file in "${SCORING_FILES[@]}"; do
        is_safeguard_file "$file" && return 0
    done
    return 1
}

_has_test_deletion_without_source() {
    [[ ${#DELETED_TEST_FILES[@]} -eq 0 ]] && return 1
    # If any test file was deleted but no source file was deleted
    if [[ ${#DELETED_SOURCE_FILES[@]} -eq 0 ]]; then
        return 0
    fi
    return 1
}

_has_exception_broadening() {
    printf '%s\n' "$DIFF_CONTENT" | grep -qE '^\+.*(except Exception|catch Exception|bare except)' 2>/dev/null && return 0
    return 1
}

_has_config_file() {
    local file
    for file in "${SCORING_FILES[@]}"; do
        # Match .claude/*.conf, .claude/settings.json, or */dso-config.conf anywhere
        if [[ "$file" =~ ^\.claude/[^/]+\.conf$ ]] || \
           [[ "$file" =~ ^\.claude/settings\.json$ ]] || \
           [[ "$file" =~ (^|/)dso-config\.conf$ ]]; then
            return 0
        fi
    done
    return 1
}

# REVIEW-DEFENSE: Finding 1 — DIFF_CONTENT is a script-level global defined at line 52
# (DIFF_CONTENT="$(cat)") and used by all floor rule functions in the same pattern
# (e.g., _has_anti_shortcut_signal, _has_exception_broadening). This function follows
# the established convention; DIFF_CONTENT is always in scope when floor rules execute.
#
# _has_external_api_signal: returns 0 if the diff adds imports of packages not
# present in any project dependency manifest (pyproject.toml, package.json,
# requirements.txt). Fail-open: if no manifest is found, returns 1 (no bump).
_has_external_api_signal() {
    # Only activate when a manifest exists — fail-open if none found.
    local manifest_file=""
    if [[ -n "$REPO_ROOT" ]]; then
        if [[ -f "$REPO_ROOT/pyproject.toml" ]]; then
            manifest_file="$REPO_ROOT/pyproject.toml"
        elif [[ -f "$REPO_ROOT/requirements.txt" ]]; then
            manifest_file="$REPO_ROOT/requirements.txt"
        elif [[ -f "$REPO_ROOT/package.json" ]]; then
            manifest_file="$REPO_ROOT/package.json"
        fi
    fi
    [[ -z "$manifest_file" ]] && return 1

    # Collect import names from added lines in the diff.
    # Matches: "import foo", "from foo import ...", "require('foo')", "require(\"foo\")"
    # Captures only the top-level package name (before any dot or slash).
    local added_imports=()
    while IFS= read -r import_name; do
        [[ -z "$import_name" ]] && continue
        added_imports+=("$import_name")
    done < <(
        printf '%s\n' "$DIFF_CONTENT" | grep -E '^\+' | \
        grep -oE '^\+[[:space:]]*(import[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)|from[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)|require\(["'"'"']([a-zA-Z_@][a-zA-Z0-9_/-]*)["'"'"']\))' | \
        sed -E 's/^\+[[:space:]]*(import[[:space:]]+|from[[:space:]]+|require\(["'"'"'])//' | \
        sed -E 's/["'"'"']\)$//' | \
        sed -E 's/^@[^/]+\///' | \
        sed -E 's/\..*//' | \
        sed -E 's/\/.*//' | \
        sort -u 2>/dev/null || true
    )

    [[ ${#added_imports[@]} -eq 0 ]] && return 1

    # Read known package names from the manifest (lowercased, normalized).
    local manifest_contents
    manifest_contents=$(python3 -c "
import sys, re, os, json

manifest = sys.argv[1]
ext = os.path.splitext(manifest)[1].lower()
known = set()

with open(manifest, 'r', errors='replace') as f:
    content = f.read()

if ext == '.toml':
    # Extract package names from pyproject.toml dependency sections only.
    # Scoped to sections containing 'dependencies' in the header to avoid
    # false negatives from metadata keys like 'name', 'version'.
    in_deps = False
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith('[') and 'dependencies' in stripped:
            in_deps = True
            continue
        if stripped.startswith('['):
            in_deps = False
            continue
        if in_deps:
            m = re.match(r'^([a-zA-Z][a-zA-Z0-9_.-]*)\s*=', stripped)
            if m:
                name = m.group(1).lower().replace('-', '_').replace('.', '_')
                known.add(name)
elif ext in ('.txt', ''):
    # requirements.txt: one package per line, may include version specifiers
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        m = re.match(r'^([a-zA-Z][a-zA-Z0-9_.-]*)', line)
        if m:
            name = m.group(1).lower().replace('-', '_').replace('.', '_')
            known.add(name)
elif ext == '.json':
    # package.json: dependencies and devDependencies
    try:
        data = json.loads(content)
        for section in ('dependencies', 'devDependencies', 'peerDependencies'):
            for pkg in data.get(section, {}):
                name = re.sub(r'^@[^/]+/', '', pkg)
                name = name.lower().replace('-', '_').replace('.', '_')
                known.add(name)
    except Exception:
        pass

print(' '.join(sorted(known)))
" "$manifest_file" 2>/dev/null || echo "")

    # Check if any added import is absent from the manifest.
    local import_name
    for import_name in "${added_imports[@]}"; do
        local normalized
        normalized=$(printf '%s' "$import_name" | tr '[:upper:]' '[:lower:]' | tr '-' '_' | tr '.' '_')
        # Skip stdlib-like names: single-word built-ins common in Python/Node
        case "$normalized" in
            os|sys|re|json|io|abc|ast|csv|math|time|enum|uuid|copy|glob|hmac|html|http|logging|pathlib|shutil|socket|struct|typing|hashlib|urllib|collections|contextlib|functools|itertools|operator|threading|subprocess|dataclasses|unittest|tempfile|warnings|traceback|textwrap|string|random|base64|binascii|codecs|decimal|fractions|numbers|calendar|datetime|locale|gettext|argparse|optparse|configparser|platform|signal|errno|ctypes|array|queue|heapq|bisect|pprint|inspect|importlib|pkgutil|gc|weakref|pickle|shelve|sqlite3|xml|html|email|mailbox|smtplib|ftplib|poplib|imaplib|telnetlib|nntplib|xmlrpc|http|urllib|ssl|select|selectors|asyncio|concurrent|multiprocessing|mmap|readline|rlcompleter|pdb|cprofile|timeit|doctest|pydoc|builtins) continue ;;
        esac
        # Check if the import is in the manifest
        if ! printf ' %s ' "$manifest_contents" | grep -qiF " $normalized " 2>/dev/null; then
            return 0  # Found an unfamiliar import
        fi
    done

    return 1
}

# ============================================================
# Diff size threshold: raw line count (excludes tests + generated)
# ============================================================
_diff_size_lines_raw() {
    local total_lines=0
    local cur_file=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^diff\ --git\ a/.*\ b/(.*) ]]; then
            cur_file="${BASH_REMATCH[1]}"
        elif [[ "${line:0:1}" == "+" && "${line:1:1}" != "+" && -n "$cur_file" ]]; then
            if ! is_test_file "$cur_file" && ! is_generated_file "$cur_file"; then
                total_lines=$(( total_lines + 1 ))
            fi
        fi
    done <<< "$DIFF_CONTENT"

    echo "$total_lines"
}

# ============================================================
# Merge commit detection
# ============================================================
_is_merge_commit() {
    # Delegate to merge-state.sh library functions when available.
    # _MERGE_STATE_GIT_DIR env var is the test isolation seam — tests set it to
    # a temp repo's .git dir so detection does not leak from the real worktree.
    if declare -f ms_is_merge_in_progress &>/dev/null; then
        ms_is_merge_in_progress && return 0
    fi
    if declare -f ms_is_rebase_in_progress &>/dev/null; then
        ms_is_rebase_in_progress && return 0
    fi

    # Fallback: direct git-dir checks when merge-state.sh is not available.
    local git_dir
    git_dir="${_MERGE_STATE_GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null || echo "")}"
    if [[ -n "$git_dir" && -s "$git_dir/MERGE_HEAD" ]]; then
        return 0
    fi
    if [[ -n "$git_dir" && -f "$git_dir/REBASE_HEAD" ]]; then
        return 0
    fi

    return 1
}

# ============================================================
# Security overlay detection
# ============================================================
_compute_security_overlay() {
    # Check file paths against security-sensitive patterns
    local file
    for file in "${SCORING_FILES[@]}"; do
        if is_security_sensitive "$file"; then
            echo "true"
            return
        fi
    done

    # Scan added lines in diff for security-sensitive imports/keywords
    # Patterns use word boundaries: 'from auth' matches 'from auth.models import ...' etc.
    if printf '%s\n' "$DIFF_CONTENT" | grep -qiE '^\+.*(from auth[. ]|import (crypto|cryptography|hashlib|hmac|secrets)([. ;]|$)|password|secret|token|credential|certificate)' 2>/dev/null; then
        echo "true"
        return
    fi

    echo "false"
}

# ============================================================
# Test quality overlay detection
# ============================================================
_compute_test_quality_overlay() {
    # Check if any changed file matches test file patterns
    local file
    for file in "${SCORING_FILES[@]}"; do
        if is_test_file "$file"; then
            echo "true"
            return
        fi
    done

    echo "false"
}

# ============================================================
# Performance overlay detection
# ============================================================
_compute_performance_overlay() {
    # Check file paths against performance-sensitive patterns
    local file
    for file in "${SCORING_FILES[@]}"; do
        if is_performance_sensitive "$file"; then
            echo "true"
            return
        fi
    done

    # Scan added lines in diff for performance-sensitive keywords
    # SQL keywords, connection pooling, async patterns, concurrency primitives
    if printf '%s\n' "$DIFF_CONTENT" | grep -qiE '^\+.*(SELECT|INSERT|UPDATE|DELETE|cursor|pool|async def|await|threading|multiprocessing)([. ;]|$)' 2>/dev/null; then
        echo "true"
        return
    fi

    echo "false"
}

# ============================================================
# Size action computation
# ============================================================
_compute_size_action() {
    local diff_size_lines="$1"
    local is_merge="$2"

    if [[ "$is_merge" == "true" ]]; then
        echo "none"
        return
    fi

    if (( diff_size_lines >= 600 )); then
        echo "reject"
    elif (( diff_size_lines >= 300 )); then
        echo "upgrade"
    else
        echo "none"
    fi
}

# ============================================================
# Compute all factors
# ============================================================
BLAST_RADIUS=$(_blast_radius)
CRITICAL_PATH=$(_critical_path)
ANTI_SHORTCUT=$(_anti_shortcut)
STALENESS=$(_staleness)
CROSS_CUTTING=$(_cross_cutting)
DIFF_LINES=$(_diff_lines)
CHANGE_VOLUME=$(_change_volume)

# Compute raw total
COMPUTED_TOTAL=$(( BLAST_RADIUS + CRITICAL_PATH + ANTI_SHORTCUT + STALENESS + CROSS_CUTTING + DIFF_LINES + CHANGE_VOLUME ))

# ============================================================
# Apply floor rules
# ============================================================
if _has_anti_shortcut_signal && (( COMPUTED_TOTAL < 3 )); then
    COMPUTED_TOTAL=3
fi

if _has_critical_path_file && (( COMPUTED_TOTAL < 3 )); then
    COMPUTED_TOTAL=3
fi

if _has_safeguard_file && (( COMPUTED_TOTAL < 3 )); then
    COMPUTED_TOTAL=3
fi

if _has_test_deletion_without_source && (( COMPUTED_TOTAL < 3 )); then
    COMPUTED_TOTAL=3
fi

if _has_exception_broadening && (( COMPUTED_TOTAL < 3 )); then
    COMPUTED_TOTAL=3
fi

if _has_config_file; then
    CONFIG_FILE_FLOOR=3
    [[ $COMPUTED_TOTAL -lt $CONFIG_FILE_FLOOR ]] && COMPUTED_TOTAL=$CONFIG_FILE_FLOOR
fi

if _has_external_api_signal && (( COMPUTED_TOTAL < 3 )); then
    COMPUTED_TOTAL=3
fi

# ============================================================
# Determine tier
# ============================================================
if (( COMPUTED_TOTAL >= 7 )); then
    SELECTED_TIER="deep"
elif (( COMPUTED_TOTAL >= 3 )); then
    SELECTED_TIER="standard"
else
    SELECTED_TIER="light"
fi

# ============================================================
# Compute diff size fields
# ============================================================
DIFF_SIZE_LINES=$(_diff_size_lines_raw)
IS_MERGE=$(_is_merge_commit && echo "true" || echo "false")

# Merge-commit floor: merges always receive at least standard tier (57ed-e776).
# Haiku's reduced context cannot reliably analyze cross-branch integration risks.
if [[ "$IS_MERGE" == "true" ]] && [[ "$SELECTED_TIER" == "light" ]]; then
    SELECTED_TIER="standard"
fi
SIZE_ACTION=$(_compute_size_action "$DIFF_SIZE_LINES" "$IS_MERGE")
SECURITY_OVERLAY=$(_compute_security_overlay)
PERFORMANCE_OVERLAY=$(_compute_performance_overlay)
TEST_QUALITY_OVERLAY=$(_compute_test_quality_overlay)

# ============================================================
# Write telemetry
# ============================================================
_artifacts_dir=""
if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
    _artifacts_dir="$ARTIFACTS_DIR"
elif declare -f get_artifacts_dir &>/dev/null; then
    _artifacts_dir=$(get_artifacts_dir 2>/dev/null || echo "")
fi
if [[ -n "$_artifacts_dir" ]]; then
    mkdir -p "$_artifacts_dir"
    _files_json="["
    _first=true
    for _f in "${SCORING_FILES[@]}"; do
        # Escape backslashes and double-quotes to produce valid JSON strings
        _f_escaped="${_f//\\/\\\\}"
        _f_escaped="${_f_escaped//\"/\\\"}"
        if $_first; then
            _files_json="${_files_json}\"${_f_escaped}\""
            _first=false
        else
            _files_json="${_files_json},\"${_f_escaped}\""
        fi
    done
    _files_json="${_files_json}]"

    printf '{"blast_radius":%d,"critical_path":%d,"anti_shortcut":%d,"staleness":%d,"cross_cutting":%d,"diff_lines":%d,"change_volume":%d,"computed_total":%d,"selected_tier":"%s","diff_size_lines":%d,"size_action":"%s","is_merge_commit":%s,"security_overlay":%s,"performance_overlay":%s,"test_quality_overlay":%s,"files":%s}\n' \
        "$BLAST_RADIUS" "$CRITICAL_PATH" "$ANTI_SHORTCUT" "$STALENESS" "$CROSS_CUTTING" "$DIFF_LINES" "$CHANGE_VOLUME" "$COMPUTED_TOTAL" "$SELECTED_TIER" "$DIFF_SIZE_LINES" "$SIZE_ACTION" "$IS_MERGE" "$SECURITY_OVERLAY" "$PERFORMANCE_OVERLAY" "$TEST_QUALITY_OVERLAY" "$_files_json" \
        >> "$_artifacts_dir/classifier-telemetry.jsonl" 2>/dev/null || true
fi

# ============================================================
# Output JSON to stdout
# ============================================================
printf '{"blast_radius":%d,"critical_path":%d,"anti_shortcut":%d,"staleness":%d,"cross_cutting":%d,"diff_lines":%d,"change_volume":%d,"computed_total":%d,"selected_tier":"%s","diff_size_lines":%d,"size_action":"%s","is_merge_commit":%s,"security_overlay":%s,"performance_overlay":%s,"test_quality_overlay":%s}' \
    "$BLAST_RADIUS" "$CRITICAL_PATH" "$ANTI_SHORTCUT" "$STALENESS" "$CROSS_CUTTING" "$DIFF_LINES" "$CHANGE_VOLUME" "$COMPUTED_TOTAL" "$SELECTED_TIER" "$DIFF_SIZE_LINES" "$SIZE_ACTION" "$IS_MERGE" "$SECURITY_OVERLAY" "$PERFORMANCE_OVERLAY" "$TEST_QUALITY_OVERLAY"

exit 0
