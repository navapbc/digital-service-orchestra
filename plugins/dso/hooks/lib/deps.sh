#!/usr/bin/env bash
# .claude/hooks/lib/deps.sh
# Shared dependency library for hooks and scripts.
#
# Provides graceful fallbacks when tools like shasum or docker are missing.
# Source this file at the top of any hook or script that needs these utilities.
#
# Functions:
#   check_tool <name>           — silent availability check (returns 0/1)
#   parse_json_field <json> <field_expr> — pure bash JSON field extraction for Claude Code hook JSON
#   hash_stdin                  — cascading hash: shasum > sha256sum > md5 > md5sum > cksum
#   hash_file <path>            — hash a file using hash_stdin
#   try_start_docker            — start Docker Desktop (macOS) or systemd (Linux), wait ≤30s
#   try_find_python <version>   — search for Python matching <version> (e.g., "3.13")
#   get_artifacts_dir           — returns portable /tmp/workflow-plugin-<hash>/ state dir (with one-time migration from old lockpick path)
#   get_timeout_cmd             — returns 'gtimeout' (macOS coreutils) or 'timeout' (Linux), empty if neither
#   resolve_repo_root           — cached REPO_ROOT resolution (REPO_ROOT → PROJECT_ROOT → CLAUDE_PROJECT_DIR → git → CLAUDE_PLUGIN_ROOT)
#   resolve_plugin_root         — cached CLAUDE_PLUGIN_ROOT resolution
#   resolve_config_file         — cached config file path resolution

# Guard: only load once
[[ "${_DEPS_LOADED:-}" == "1" ]] && return 0
_DEPS_LOADED=1

# --- check_tool ---
# Usage: check_tool shasum && echo "shasum available"
#        check_tool docker || exit 0
check_tool() {
    command -v "$1" &>/dev/null
}

# --- parse_json_field ---
# Extract a field from JSON using pure bash string parsing for the known
# Claude Code hook JSON shape:
#   {"tool_name":"...","tool_input":{"command":"...","file_path":"..."}}
#
# Supports:
#   .tool_name              — top-level string field
#   .tool_input.command     — nested field under tool_input
#   .tool_input.file_path   — nested field under tool_input
#   .error                  — top-level string field
#   .session_id             — top-level string field
#   .is_interrupt           — top-level string field
#
# Returns empty string on failure (never errors out).
#
# Usage: TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
#        COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
parse_json_field() {
    local json="$1"
    local expr="$2"

    # Handle the known Claude Code hook JSON shape
    # Strip leading dot from expression
    local field="${expr#.}"

    if [[ "$field" == *"."* ]]; then
        # Nested field: e.g., "tool_input.command" or "a.b.c"
        local parent="${field%%.*}"
        local child="${field#*.}"

        # Extract the parent object's value (everything between the outermost braces
        # after the parent key). This is a simplified parser for the known JSON shape.
        local parent_val=""
        parent_val=$(_deps_extract_object_field "$json" "$parent")

        if [[ -z "$parent_val" ]]; then
            echo ""
            return 0
        fi

        # Recurse for multi-level nesting (e.g., "b.c" in parent_val)
        if [[ "$child" == *"."* ]]; then
            parse_json_field "$parent_val" ".$child"
        else
            _deps_extract_string_field "$parent_val" "$child"
        fi
    else
        # Top-level field — check for array values and warn
        if [[ "$json" =~ \"${field}\"[[:space:]]*:[[:space:]]*\[ ]]; then
            echo "parse_json_field: field '.$field' contains an array value (not supported)" >&2
            echo ""
            return 0
        fi
        _deps_extract_string_field "$json" "$field"
    fi
}

# Internal: extract a JSON object value (brace-matched) from JSON by key.
# Returns the full object including braces, or empty string.
_deps_extract_object_field() {
    local json="$1"
    local key="$2"

    if [[ "$json" =~ \"${key}\"[[:space:]]*:[[:space:]]*\{ ]]; then
        local after="${json#*\""${key}"\"*:\{}"
        local depth=1
        local i=0
        local len=${#after}
        while (( i < len && depth > 0 )); do
            local ch="${after:$i:1}"
            [[ "$ch" == "{" ]] && (( depth++ ))
            [[ "$ch" == "}" ]] && (( depth-- ))
            (( i++ ))
        done
        echo "{${after:0:$i}"
    else
        echo ""
    fi
}

# Internal: extract a simple string field value from JSON
# Handles: "key":"value" and "key": "value" with possible escapes
_deps_extract_string_field() {
    local json="$1"
    local key="$2"

    # Match "key" : "value" — capture the value (handle escaped quotes)
    # Use a simple approach: find the key, then extract between the next pair of quotes
    if [[ "$json" =~ \"${key}\"[[:space:]]*:[[:space:]]*\" ]]; then
        local after="${json#*\""${key}"\"*:*\"}"
        # Read until unescaped quote (handle \\" correctly — count consecutive backslashes)
        local result=""
        local i=0
        local len=${#after}
        while (( i < len )); do
            local ch="${after:$i:1}"
            if [[ "$ch" == '"' ]]; then
                # Count consecutive backslashes before this quote
                local bs_count=0
                local j=$((i - 1))
                while (( j >= 0 )) && [[ "${after:$j:1}" == "\\" ]]; do
                    (( bs_count++ ))
                    (( j-- ))
                done
                # Even number of backslashes = quote is NOT escaped (they escape each other)
                if (( bs_count % 2 == 0 )); then
                    break
                else
                    result="${result}${ch}"
                fi
            else
                result="${result}${ch}"
            fi
            (( i++ ))
        done
        echo "$result"
    elif [[ "$json" =~ \"${key}\"[[:space:]]*:[[:space:]]*([0-9.]+|true|false|null) ]]; then
        # Non-string value (number, boolean, null)
        local after="${json#*\""${key}"\"*:}"
        after="${after#"${after%%[![:space:]]*}"}"  # trim leading whitespace
        # Read until comma, brace, or bracket
        local result=""
        local i=0
        local len=${#after}
        while (( i < len )); do
            local ch="${after:$i:1}"
            [[ "$ch" == "," || "$ch" == "}" || "$ch" == "]" ]] && break
            result="${result}${ch}"
            (( i++ ))
        done
        # Trim trailing whitespace
        result="${result%"${result##*[![:space:]]}"}"
        echo "$result"
    else
        echo ""
    fi
}

# --- hash_stdin ---
# Read stdin and produce a hex hash string. Uses the best available tool:
#   shasum -a 256 > sha256sum > md5 > md5sum > cksum
#
# Usage: echo "data" | hash_stdin
#        HASH=$(cat file | hash_stdin)
hash_stdin() {
    if check_tool shasum; then
        shasum -a 256 | awk '{print $1}'
    elif check_tool sha256sum; then
        sha256sum | awk '{print $1}'
    elif check_tool md5; then
        md5
    elif check_tool md5sum; then
        md5sum | awk '{print $1}'
    elif check_tool cksum; then
        cksum | awk '{print $1}'
    else
        # Last resort: just read and discard, output a placeholder
        cat >/dev/null
        echo "no-hash-tool-available"
    fi
}

# --- hash_file ---
# Hash a file's contents using hash_stdin.
#
# Usage: HASH=$(hash_file /path/to/file)
hash_file() {
    local filepath="$1"
    hash_stdin < "$filepath"
}

# --- try_start_docker ---
# Attempt to start Docker if the CLI exists but the daemon isn't running.
# macOS: opens Docker Desktop. Linux: tries systemctl.
# Waits up to 30 seconds for the daemon to respond.
#
# Returns: 0 if docker is responding, 1 if start failed or timed out.
try_start_docker() {
    # Already running?
    if docker info &>/dev/null 2>&1; then
        return 0
    fi

    # No docker CLI at all
    if ! check_tool docker; then
        return 1
    fi

    # Attempt to start
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: open Docker Desktop
        open -a "Docker Desktop" 2>/dev/null || open -a "Docker" 2>/dev/null || return 1
    else
        # Linux: try systemd (use sudo -n to avoid blocking on password prompt)
        if check_tool systemctl; then
            sudo -n systemctl start docker 2>/dev/null || return 1
        else
            return 1
        fi
    fi

    # Wait up to 30 seconds
    local waited=0
    while (( waited < 30 )); do
        if docker info &>/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        (( waited += 2 ))
    done

    return 1
}

# --- try_find_python ---
# Search common locations for a Python binary matching the requested version.
# Returns the full path on stdout, or empty string if not found.
#
# Usage: PYTHON=$(try_find_python 3.13)
#        [[ -n "$PYTHON" ]] && echo "Found: $PYTHON"
# --- get_artifacts_dir ---
# Returns the portable state directory path for this repo.
#
# New path: /tmp/workflow-plugin-<16-char-hash-of-REPO_ROOT>/
#
# Backward-compat: if old /tmp/lockpick-test-artifacts-<worktree>/ exists
# and the new path has no state files, performs a one-time atomic migration
# by copying files from the old directory to the new directory.
#
# The migration is guarded by an atomic mkdir lock to be safe under concurrent
# invocations. Old directories are left in place (OS temp cleanup handles them).
#
# Usage: ARTIFACTS_DIR=$(get_artifacts_dir)
get_artifacts_dir() {
    # Allow tests to override the artifacts directory for isolation
    if [[ -n "${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-}" ]]; then
        mkdir -p "$WORKFLOW_PLUGIN_ARTIFACTS_DIR"
        echo "$WORKFLOW_PLUGIN_ARTIFACTS_DIR"
        return 0
    fi

    local repo_root=${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}
    [[ -z "$repo_root" ]] && echo "/tmp/workflow-plugin-unknown" && return 0

    local hash_suffix
    hash_suffix=$(echo -n "$repo_root" | hash_stdin | head -c 16)
    local new_dir="/tmp/workflow-plugin-${hash_suffix}"
    mkdir -p "$new_dir"

    # One-time backward-compat migration from old lockpick path
    local worktree_name
    worktree_name=$(basename "$repo_root")
    local old_dir="/tmp/lockpick-test-artifacts-${worktree_name}"
    local lock_dir="/tmp/workflow-plugin-migration-${hash_suffix}.lock"

    if [[ -d "$old_dir" ]] && [[ -z "$(ls -A "$new_dir" 2>/dev/null)" ]]; then
        # Atomic lock using mkdir (atomic on Linux/macOS)
        if mkdir "$lock_dir" 2>/dev/null; then
            # We hold the lock — re-check new_dir is still empty before migrating
            if [[ -z "$(ls -A "$new_dir" 2>/dev/null)" ]]; then
                cp -r "$old_dir"/. "$new_dir"/ 2>/dev/null || true
            fi
            rmdir "$lock_dir" 2>/dev/null || true
        fi
        # If lock failed, another process is migrating — new_dir will be populated shortly
    fi

    echo "$new_dir"
}

# --- is_worktree ---
# Returns 0 (true) if the current working directory is inside a git worktree
# (i.e., the repo's .git entry is a FILE, not a directory). Returns 1 otherwise.
#
# In a normal repo:   $TOPLEVEL/.git is a directory  → returns 1
# In a git worktree: $TOPLEVEL/.git is a file        → returns 0
#
# Usage:
#   if is_worktree; then
#     echo "Running inside a worktree"
#   fi
is_worktree() {
    local toplevel
    toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    [[ -f "$toplevel/.git" ]]
}

# --- get_timeout_cmd ---
# Returns the GNU timeout command name for the current platform.
# macOS: gtimeout (from brew install coreutils)
# Linux: timeout (built-in)
# Returns empty string and exit 1 if neither is available.
#
# Usage:
#   TIMEOUT_CMD=$(get_timeout_cmd) || { echo "timeout not available"; exit 1; }
#   $TIMEOUT_CMD 180 make test-unit-only
get_timeout_cmd() {
    if command -v gtimeout &>/dev/null; then
        echo "gtimeout"
    elif command -v timeout &>/dev/null; then
        echo "timeout"
    else
        return 1
    fi
}

# --- resolve_repo_root ---
# Resolves the repository root directory using a reliable fallback chain.
# Result is cached in _RESOLVED_REPO_ROOT after first call.
#
# Fallback chain:
#   1. REPO_ROOT (if already set by caller)
#   2. PROJECT_ROOT (test isolation override)
#   3. CLAUDE_PROJECT_DIR (official Claude Code env var — set at runtime)
#   4. git rev-parse --show-toplevel
#   5. CLAUDE_PLUGIN_ROOT/../.. (only in local dev — validated by .git presence)
#
# Works in: normal repos, git worktrees, plugin cache installs, CI.
#
# Usage:
#   REPO_ROOT=$(resolve_repo_root)
resolve_repo_root() {
    # Return cached value if available
    if [[ -n "${_RESOLVED_REPO_ROOT:-}" ]]; then
        echo "$_RESOLVED_REPO_ROOT"
        return 0
    fi

    local root=""

    # 1. Explicit REPO_ROOT (caller override)
    if [[ -n "${REPO_ROOT:-}" ]]; then
        root="$REPO_ROOT"
    fi

    # 2. PROJECT_ROOT (test isolation)
    if [[ -z "$root" && -n "${PROJECT_ROOT:-}" ]]; then
        root="$PROJECT_ROOT"
    fi

    # 3. CLAUDE_PROJECT_DIR (official Claude Code env var — works even outside git repos
    #    and in plugin cache scenarios where git rev-parse can't find the project)
    if [[ -z "$root" && -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
        root="$CLAUDE_PROJECT_DIR"
    fi

    # 4. git rev-parse (works in normal repos and worktrees)
    if [[ -z "$root" ]]; then
        root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    fi

    # 5. CLAUDE_PLUGIN_ROOT-based (plugin is at ${CLAUDE_PLUGIN_ROOT}/ in local dev).
    # Only use when the derived path has .git (dir or file), confirming it's
    # a real repo root. In plugin cache (~/.claude/${CLAUDE_PLUGIN_ROOT}/), ../../ would
    # resolve to a non-repo path — the .git check prevents that.
    if [[ -z "$root" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "$CLAUDE_PLUGIN_ROOT" ]]; then
        local _candidate
        _candidate=$(cd "$CLAUDE_PLUGIN_ROOT" && cd ../.. && pwd 2>/dev/null || echo "")
        if [[ -n "$_candidate" && ( -d "$_candidate/.git" || -f "$_candidate/.git" ) ]]; then
            root="$_candidate"
        fi
    fi

    _RESOLVED_REPO_ROOT="$root"
    echo "$root"
}

# --- resolve_plugin_root ---
# Resolves the DSO plugin root directory (${CLAUDE_PLUGIN_ROOT}/).
# Result is cached in _RESOLVED_PLUGIN_ROOT after first call.
#
# Fallback chain:
#   1. CLAUDE_PLUGIN_ROOT (if set and contains hooks/)
#   2. Self-location via BASH_SOURCE[0] (hooks/lib/deps.sh → ../../ = plugin root)
#
# Usage:
#   PLUGIN_ROOT=$(resolve_plugin_root)
resolve_plugin_root() {
    if [[ -n "${_RESOLVED_PLUGIN_ROOT:-}" ]]; then
        echo "$_RESOLVED_PLUGIN_ROOT"
        return 0
    fi

    local root=""

    # 1. CLAUDE_PLUGIN_ROOT if valid
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "$CLAUDE_PLUGIN_ROOT/hooks" ]]; then
        root="$CLAUDE_PLUGIN_ROOT"
    fi

    # 2. Derive from this file's location (hooks/lib/deps.sh → ../../ = plugin root)
    if [[ -z "$root" ]]; then
        local self_root
        self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        if [[ -d "$self_root/hooks" ]]; then
            root="$self_root"
        fi
    fi

    _RESOLVED_PLUGIN_ROOT="$root"
    echo "$root"
}

# --- resolve_config_file ---
# Resolves the path to .claude/dso-config.conf.
# Result is cached in _RESOLVED_CONFIG_FILE after first call.
#
# Fallback chain:
#   1. WORKFLOW_CONFIG_FILE (test/override)
#   2. REPO_ROOT/.claude/dso-config.conf
#
# Returns empty string and exit 0 if no config file found (graceful degradation).
#
# Usage:
#   CONFIG_FILE=$(resolve_config_file)
#   [[ -n "$CONFIG_FILE" ]] && source read-config.sh "$CONFIG_FILE" key
resolve_config_file() {
    if [[ -n "${_RESOLVED_CONFIG_FILE:-}" ]]; then
        echo "$_RESOLVED_CONFIG_FILE"
        return 0
    fi

    local config=""

    # 1. Explicit override
    if [[ -n "${WORKFLOW_CONFIG_FILE:-}" && -f "${WORKFLOW_CONFIG_FILE}" ]]; then
        config="$WORKFLOW_CONFIG_FILE"
    fi

    # 2. Standard location relative to repo root
    if [[ -z "$config" ]]; then
        local repo_root
        repo_root=$(resolve_repo_root)
        if [[ -n "$repo_root" && -f "$repo_root/.claude/dso-config.conf" ]]; then
            config="$repo_root/.claude/dso-config.conf"
        fi
    fi

    _RESOLVED_CONFIG_FILE="$config"
    echo "$config"
}

# --- parse_json_object ---
# Extract a JSON object value from a JSON string using brace-matching.
# Like jq -c '.key // {}' but in pure bash.
#
# Usage: OBJ=$(parse_json_object "$JSON" '.tool_input')
parse_json_object() {
    local json="$1"
    local expr="$2"
    local field="${expr#.}"

    # Find "field":{
    if [[ "$json" =~ \"${field}\"[[:space:]]*:[[:space:]]*\{ ]]; then
        # Get everything starting from the opening brace
        local after="${json#*\""${field}"\"*:}"
        # Trim leading whitespace
        after="${after#"${after%%[![:space:]]*}"}"
        # Now balance braces, respecting strings
        local depth=0
        local i=0
        local len=${#after}
        local in_string=0
        local prev_ch=""
        while (( i < len )); do
            local ch="${after:$i:1}"
            if (( in_string )); then
                if [[ "$ch" == '"' && "$prev_ch" != "\\" ]]; then
                    in_string=0
                fi
            else
                if [[ "$ch" == '"' ]]; then
                    in_string=1
                elif [[ "$ch" == "{" ]]; then
                    (( depth++ ))
                elif [[ "$ch" == "}" ]]; then
                    (( depth-- ))
                    if (( depth == 0 )); then
                        echo "${after:0:$((i+1))}"
                        return 0
                    fi
                fi
            fi
            prev_ch="$ch"
            (( i++ ))
        done
    fi
    echo ""
}

# --- json_build ---
# Construct a compact JSON object from key=value pairs.
# Suffix :n on the key name indicates numeric (no quotes). Default is string (quoted).
#
# Usage: json_build ts="2026-01-01" count:n=42 name="Alice"
#        → {"ts":"2026-01-01","count":42,"name":"Alice"}
json_build() {
    local parts=()
    for arg in "$@"; do
        local key_part="${arg%%=*}"
        local val="${arg#*=}"
        if [[ "$key_part" == *":n" ]]; then
            # Numeric: strip :n suffix, no quotes on value
            local key="${key_part%:n}"
            parts+=("\"${key}\":${val}")
        else
            # String: escape special characters for valid JSON
            local key="$key_part"
            # Use python3 for reliable JSON string escaping
            local escaped_val
            escaped_val=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()),end='')" <<< "$val"  2>/dev/null)
            if [[ $? -eq 0 && -n "$escaped_val" ]]; then
                # python3 wraps in quotes already, but we read with trailing newline from <<<
                # Use python to escape the exact value (without trailing newline from <<<)
                escaped_val=$(printf '%s' "$val" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()),end='')" 2>/dev/null)
                parts+=("\"${key}\":${escaped_val}")
            else
                # Fallback: basic escaping
                val="${val//\\/\\\\}"
                val="${val//\"/\\\"}"
                val="${val//$'\n'/\\n}"
                val="${val//$'\r'/\\r}"
                val="${val//$'\t'/\\t}"
                parts+=("\"${key}\":\"${val}\"")
            fi
        fi
    done
    # Join with commas
    local result="{"
    local first=1
    for part in "${parts[@]}"; do
        if (( first )); then
            result="${result}${part}"
            first=0
        else
            result="${result},${part}"
        fi
    done
    result="${result}}"
    echo "$result"
}

# --- json_mutate ---
# Run a python3 one-liner to mutate JSON data.
# The python snippet receives the parsed JSON as 'data' and should modify it in place.
#
# Usage (stdin):  echo '{"a":1}' | json_mutate 'data["b"]=2'
# Usage (file):   json_mutate 'data["b"]=2' /path/to/file.json
# Output: modified JSON on stdout
json_mutate() {
    local snippet="$1"
    local file="${2:-}"

    if ! check_tool python3; then
        echo "ERROR: json_mutate requires python3" >&2
        return 1
    fi

    local python_script
    python_script="import json,sys
data=json.load(sys.stdin)
${snippet}
print(json.dumps(data))"

    if [[ -n "$file" ]]; then
        python3 -c "$python_script" < "$file"
    else
        python3 -c "$python_script"
    fi
}

# --- json_filter_jsonl ---
# Filter lines of a JSONL file using a python3 filter expression.
# Each line is parsed as JSON and available as 'data' in the expression.
# Lines where the expression evaluates to True are output.
#
# Usage: json_filter_jsonl /path/to/file.jsonl 'data.get("age",0) > 28'
# Output: matching JSONL lines on stdout
json_filter_jsonl() {
    local file="$1"
    local filter_expr="$2"

    if ! check_tool python3; then
        echo "ERROR: json_filter_jsonl requires python3" >&2
        return 1
    fi

    # Handle empty files
    if [[ ! -s "$file" ]]; then
        return 0
    fi

    python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    data = json.loads(line)
    if ${filter_expr}:
        print(line)
" < "$file"
}

# --- json_summarize_input ---
# Summarize a JSON object's keys and values for logging.
# Values are truncated to 80 characters.
# Replaces: jq -r 'to_entries | map(.key + "=" + (.value | tostring | .[0:80])) | join(", ")'
#
# Usage: SUMMARY=$(json_summarize_input '{"command":"git status","file":"/tmp/x"}')
#        → command=git status, file=/tmp/x
json_summarize_input() {
    local json="$1"

    if check_tool python3; then
        python3 -c "
import json, sys
data = json.loads(sys.argv[1])
parts = []
for k, v in data.items():
    s = json.dumps(v) if v is None else str(v)
    s = s[:80]
    parts.append(k + '=' + s)
print(', '.join(parts))
" "$json" 2>/dev/null
        return
    fi

    # Bash fallback: extract key-value pairs using grep
    # This handles simple flat JSON objects
    local result=""
    local pairs
    pairs=$(echo "$json" | grep -oE '"[^"]+"\s*:\s*("[^"]*"|[0-9.]+|true|false|null)' || true)
    while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        local key val
        key=$(echo "$pair" | grep -oE '^"[^"]+"' | tr -d '"')
        val=$(echo "$pair" | sed 's/^"[^"]*"\s*:\s*//' | tr -d '"')
        val="${val:0:80}"
        if [[ -n "$result" ]]; then
            result="${result}, "
        fi
        result="${result}${key}=${val}"
    done <<< "$pairs"
    echo "$result"
}

# --- _load_allowlist_patterns ---
# Load glob patterns from an allowlist file, skipping comments and blank lines.
# Outputs parsed patterns as newline-separated list on stdout.
# Returns non-zero and prints warning to stderr if file not found.
#
# Usage: PATTERNS=$(_load_allowlist_patterns /path/to/allowlist.conf)
_load_allowlist_patterns() {
    local allowlist_path="$1"

    if [[ ! -f "$allowlist_path" ]]; then
        echo "WARNING: allowlist file not found: $allowlist_path" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        echo "$line"
    done < "$allowlist_path"
}

# --- _allowlist_to_pathspecs ---
# Convert newline-separated glob patterns to git pathspec exclusions (prefix :!).
# Outputs one pathspec per line on stdout.
#
# Usage: PATHSPECS=$(_allowlist_to_pathspecs "$PATTERNS")
#        git diff ... -- $PATHSPECS
_allowlist_to_pathspecs() {
    local patterns="$1"

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        echo ":!${pattern}"
    done <<< "$patterns"
}

# --- _allowlist_to_grep_regex ---
# Convert newline-separated glob patterns to a grep-compatible regex string.
# Each pattern becomes a line-anchored regex. Handles:
#   . → \., ** → .*, * → [^/]*, leading dot preserved with escape.
# Outputs one regex line per pattern on stdout.
#
# Usage: REGEX=$(_allowlist_to_grep_regex "$PATTERNS")
#        echo "$file" | grep -qE "$REGEX"
_allowlist_to_grep_regex() {
    local patterns="$1"

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        local regex="$pattern"
        # Order matters: use placeholders to avoid substitution interference
        # Step 1: Replace ** with placeholder before touching single *
        regex="${regex//\*\*/@@DOUBLESTAR@@}"
        # Step 2: Replace single * with [^/]* (match within path segment)
        regex="${regex//\*/[^/]*}"
        # Step 3: Replace placeholder with .* (match any path depth)
        regex="${regex//@@DOUBLESTAR@@/.*}"
        # Step 4: Escape literal dots (but not the .* we just inserted)
        # We escape dots that are NOT followed by * (i.e., literal dots)
        # Use a two-pass approach: protect .* first, escape dots, restore .*
        regex="${regex//\.\*/@@DOTSTAR@@}"
        regex="${regex//./\\.}"
        regex="${regex//@@DOTSTAR@@/.*}"
        # Step 5: Anchor to start of line
        regex="^${regex}"
        echo "$regex"
    done <<< "$patterns"
}

# --- EXCLUDE_PATTERNS ---
# Array of path patterns that hooks should skip.
# Entries are substring patterns — a file path matching any entry is excluded.
#
# .tickets-tracker/ — ticket files managed by the ticket CLI; hooks should not interfere.
#
# Usage:
#   for pat in "${EXCLUDE_PATTERNS[@]}"; do
#     if [[ "$file_path" == *"$pat"* ]]; then skip; fi
#   done
EXCLUDE_PATTERNS=(
    ".tickets-tracker/"
    ".git/"
)

try_find_python() {
    local version="$1"
    local major="${version%%.*}"
    local minor="${version#*.}"

    # Candidate paths to check (in priority order)
    local candidates=(
        "/opt/homebrew/opt/python@${version}/bin/python${version}"
        "/opt/homebrew/opt/python@${version}/bin/python${major}"
        "/opt/homebrew/bin/python${version}"
        "/usr/local/opt/python@${version}/bin/python${version}"
        "/usr/local/bin/python${version}"
    )

    # pyenv versions
    if check_tool pyenv; then
        local pyenv_root
        pyenv_root=$(pyenv root 2>/dev/null || echo "$HOME/.pyenv")
        # Find installed versions matching the requested version
        local pyenv_versions
        pyenv_versions=$(ls -d "${pyenv_root}/versions/${version}"* 2>/dev/null || true)
        for pv in $pyenv_versions; do
            candidates+=("${pv}/bin/python${major}")
            candidates+=("${pv}/bin/python${version}")
        done
    fi

    # System paths
    candidates+=(
        "/usr/bin/python${version}"
        "/usr/bin/python${major}"
    )

    # Check each candidate
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            # Verify version actually matches
            local actual_version
            actual_version=$("$candidate" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ "$actual_version" == "${major}.${minor}" ]]; then
                echo "$candidate"
                return 0
            fi
        fi
    done

    # Fallback: check PATH for python3.X or pythonX.Y
    local path_python
    path_python=$(command -v "python${version}" 2>/dev/null || true)
    if [[ -n "$path_python" ]]; then
        local actual_version
        actual_version=$("$path_python" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [[ "$actual_version" == "${major}.${minor}" ]]; then
            echo "$path_python"
            return 0
        fi
    fi

    echo ""
    return 1
}

# --- atomic_write_file ---
# Write content to a file atomically using write-to-temp + rename.
# Prevents partial reads during concurrent access.
#
# Usage: atomic_write_file <target_path> <content>
#        echo "data" | atomic_write_file <target_path> -
#
# The second form reads content from stdin when the content arg is "-".
# Creates parent directories if they don't exist.
atomic_write_file() {
    local target="$1"
    local content="${2:-}"
    local target_dir
    target_dir=$(dirname "$target")

    # Ensure parent directory exists
    mkdir -p "$target_dir"

    # Write to temp file in the same directory (same filesystem for atomic rename)
    local tmpf
    tmpf=$(mktemp "${target_dir}/$(basename "$target").tmp.XXXXXX")

    if [[ "$content" == "-" ]]; then
        cat > "$tmpf"
    else
        printf '%s\n' "$content" > "$tmpf"
    fi

    # Atomic rename (POSIX guarantees rename is atomic on same filesystem)
    mv "$tmpf" "$target"
}

# --- create_managed_tempdir ---
# Create a temporary directory and register an EXIT trap to clean it up.
# Chains with any existing EXIT trap instead of replacing it.
# Sets the given variable name to the created temp directory path in the calling scope.
#
# IMPORTANT: Must NOT be called via command substitution (e.g., VAR=$(create_managed_tempdir VAR))
# because subshell execution causes the EXIT trap to fire immediately when the subshell exits,
# deleting the directory before the caller can use it. Always call as:
#
#   create_managed_tempdir VARNAME
#   # Now $VARNAME holds the path, and it will be removed on any exit (normal or error)
#
# Usage:
#   create_managed_tempdir MY_TMPDIR
#   echo "Using temp dir: $MY_TMPDIR"
create_managed_tempdir() {
    local _varname="${1:-_MANAGED_TMPDIR}"
    local _tmpdir
    _tmpdir=$(mktemp -d)

    # Chain the cleanup with any existing EXIT trap.
    # Capture the current trap action (if any) for this signal.
    local _existing_trap
    _existing_trap=$(trap -p EXIT 2>/dev/null | sed "s/^trap -- '\\(.*\\)' EXIT\$/\\1/" || true)

    if [[ -n "$_existing_trap" ]]; then
        # Chain: run existing trap first, then remove our temp dir
        # shellcheck disable=SC2064
        trap "${_existing_trap}; rm -rf '${_tmpdir}'" EXIT
    else
        # No existing trap — set a new one
        # shellcheck disable=SC2064
        trap "rm -rf '${_tmpdir}'" EXIT
    fi

    # Set the variable in the caller's scope using declare -g
    # shellcheck disable=SC2140
    declare -g "$_varname"="$_tmpdir"
}

# --- cleanup_stale_tmpdirs ---
# Find and remove /tmp/lw-* and /tmp/test-batched-* directories/files
# older than 24 hours. Safe to call at any time; tolerates missing entries.
#
# Usage:
#   cleanup_stale_tmpdirs
cleanup_stale_tmpdirs() {
    local cutoff_hours="${1:-24}"
    local min_cutoff="${cutoff_hours}"

    # find -mmin: files older than N*60 minutes
    local find_mmin=$(( min_cutoff * 60 ))

    # Remove stale lw-* temp dirs/files
    find /tmp -maxdepth 1 \( -name 'lw-*' -o -name 'test-batched-*' \) \
        -mmin "+${find_mmin}" \
        -exec rm -rf {} + 2>/dev/null || true
}

# --- retry_with_backoff ---
# Retry a command with exponential backoff on failure.
#
# Usage: retry_with_backoff <max_retries> <initial_delay_sec> <command> [args...]
#
# Runs the command once. On failure, retries up to max_retries times with
# exponential backoff (delay doubles each retry). Returns the command's exit
# code on success, or the last failure exit code after exhausting retries.
#
# Example:
#   retry_with_backoff 4 2 git push -u origin main
#   # Tries once, then retries up to 4 times with delays: 2s, 4s, 8s, 16s
retry_with_backoff() {
    local max_retries="$1"
    local delay="$2"
    shift 2
    local cmd=("$@")

    local attempt=0
    local exit_code=0

    # Initial attempt
    "${cmd[@]}" && return 0
    exit_code=$?
    attempt=1

    # Retry loop
    while (( attempt <= max_retries )); do
        echo "retry_with_backoff: attempt $attempt/$max_retries failed (exit $exit_code), retrying in ${delay}s..." >&2
        sleep "$delay"
        delay=$(awk "BEGIN {printf \"%.2f\", $delay * 2}" 2>/dev/null || echo "$((${delay%.*} * 2))")
        exit_code=0
        "${cmd[@]}" && return 0
        exit_code=$?
        (( attempt++ ))
    done

    echo "retry_with_backoff: all $max_retries retries exhausted (exit $exit_code)" >&2
    return "$exit_code"
}
